import 'dart:async';

import '../../../../core/utils/result.dart';
import '../../domain/models/print_job.dart';
import '../../domain/models/print_profile.dart';
import '../../domain/models/printer_capabilities.dart';
import '../../domain/models/printer_connection.dart';
import '../../domain/models/printer_connection_settings.dart';
import '../../domain/models/printer_status.dart';
import '../../domain/printers/active_printer.dart';
import '../../domain/printers/thermal_printer.dart';
import '../../domain/printers/thermal_printer_factory.dart';

/// The printer the application holds, which is whichever printer is configured now.
///
/// ## Why a delegate rather than rebuilding the print service
///
/// `DefaultPrintService` takes a printer once, in the bootstrap, and so do the encoder and
/// every screen that shows a status. If saving a new address meant rebuilding that graph,
/// a print already in flight would be sent to an object nobody held any more, and every
/// widget with a live subscription would have to be told to re-read its provider.
///
/// One stable object with a swappable delegate avoids all of it. The print service keeps
/// the same `ThermalPrinter` for the life of the application; what changes underneath is
/// where the bytes go.
///
/// ## Ordering
///
/// A swap happens between documents, never inside one. [send] delegates to the current
/// printer, and each concrete printer serialises its own writes, so the only way a
/// reconfiguration could interleave with a document is if [apply] were called while a
/// send was outstanding — which it is not, because both are driven from the same UI
/// isolate and [apply] awaits the release of the old printer before adopting the new one.
///
/// ## It adds no capability
///
/// It cannot print anything its delegate cannot. Bound to a terminal with no transport
/// adapter, every send fails with the delegate's own message, which is the honest state
/// of this build. See `NoTransportPrinterFactory`.
class ConfigurableThermalPrinter implements ThermalPrinter, ActivePrinter {
  ConfigurableThermalPrinter({
    required ThermalPrinterFactory factory,
    PrinterConnectionSettings settings = PrinterConnectionSettings.unconfigured,
  }) : _factory = factory,
       _settings = settings {
    _adopt(factory.create(settings));
  }

  final ThermalPrinterFactory _factory;

  /// Republishes the current delegate's states under one subscription.
  ///
  /// Broadcast, and owned here rather than forwarded, so a listener survives a
  /// reconfiguration: it keeps the same stream while the printer behind it is replaced.
  final StreamController<PrinterConnectionState> _states =
      StreamController<PrinterConnectionState>.broadcast();

  PrinterConnectionSettings _settings;
  late ThermalPrinter _delegate;
  late PrinterTransportSupport _support;

  /// The delegate's state subscription, cancelled when the delegate is replaced.
  StreamSubscription<PrinterConnectionState>? _delegateStates;

  bool _isDisposed = false;

  /// The printer in use, for a test or a diagnostic that needs the concrete object.
  ThermalPrinter get delegate => _delegate;

  // ------------------------------------------------------------ active printer ---

  @override
  PrinterConnectionSettings get connectionSettings => _settings;

  @override
  PrinterStatus get status => PrinterStatus(
    settings: _settings,
    connectionState: _delegate.connectionState,
    support: _support,
    endpoint: _delegate.endpoint,
  );

  @override
  Stream<PrinterConnectionState> get connectionStates async* {
    // The current state first, so a widget built after a change does not sit on a stale
    // value while waiting for the next one.
    yield _delegate.connectionState;
    yield* _states.stream;
  }

  @override
  Future<Result<void>> apply(PrinterConnectionSettings settings) async {
    if (_isDisposed) {
      return const Ok<void>(null);
    }

    // Released before the new one is adopted, so a terminal repointed from one network
    // printer to another does not leave a socket open on the first. The disconnect is
    // what can fail and be worth reporting; the dispose after it only releases the state
    // stream and cannot.
    final Result<void> released = await _delegate.disconnect();
    await _delegateStates?.cancel();
    _delegateStates = null;
    await _delegate.dispose();

    _settings = settings;
    _adopt(_factory.create(settings));

    // The state of the new printer, published to whoever is watching the indicator.
    _publish(_delegate.connectionState);

    return released;
  }

  // ---------------------------------------------------------- thermal printer ---

  @override
  PrinterConnectionState get connectionState => _delegate.connectionState;

  @override
  PrinterEndpoint? get endpoint => _delegate.endpoint;

  @override
  PrinterCapabilities get capabilities => _delegate.capabilities;

  @override
  PrintProfile get profile => _delegate.profile;

  @override
  Future<Result<void>> connect() => _delegate.connect();

  @override
  Future<Result<void>> disconnect() => _delegate.disconnect();

  @override
  Future<Result<void>> send(PrintJob job) => _delegate.send(job);

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _delegateStates?.cancel();
    _delegateStates = null;
    await _delegate.dispose();
    await _states.close();
  }

  // --------------------------------------------------------------- internals ---

  /// Takes [resolution] as the printer in use and follows its state stream.
  void _adopt(PrinterResolution resolution) {
    _delegate = resolution.printer;
    _support = resolution.support;
    _delegateStates?.cancel();
    _delegateStates = _delegate.connectionStates.listen(
      _publish,
      // A transport whose state stream fails is still a printer; the fault surfaces from
      // the next send, with a message the operator can act on. Swallowed here so that a
      // stream error cannot become an unhandled exception during a bill.
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _publish(PrinterConnectionState state) {
    if (!_isDisposed && !_states.isClosed) {
      _states.add(state);
    }
  }
}
