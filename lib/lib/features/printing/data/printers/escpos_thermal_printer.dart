import 'dart:async';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/print_job.dart';
import '../../domain/models/print_profile.dart';
import '../../domain/models/printer_capabilities.dart';
import '../../domain/models/printer_connection.dart';
import '../../domain/printers/thermal_printer.dart';

/// Everything an ESC/POS printer does except move bytes.
///
/// ## The seam
///
/// This class owns the parts that are identical for every ESC/POS printer: the
/// connection state machine, the state stream, turning a thrown transport error into a
/// [PrinterFailure], and refusing to interleave two documents. A transport adapter
/// supplies the three things that actually differ — [openTransport], [closeTransport]
/// and [writeToTransport] — and nothing else.
///
/// That is the whole of the hardware requirement. A `UsbEscPosPrinter` opens a device
/// handle and writes to it; a `LanEscPosPrinter` opens a socket to port 9100 and writes
/// to it. Both are a few dozen lines, both inherit the identical error handling, and
/// neither is visible to billing, checkout or the kitchen slip, which know only
/// [ThermalPrinter].
///
/// ## No formatter
///
/// A job arriving here is already encoded. This class never sees a document, a paper
/// width or a column count, which is deliberate: layout belongs to the encoder, and a
/// transport that could reformat a bill would be a transport that could change one.
///
/// ## Why no adapter ships in this build
///
/// The printer has not been bought. Writing a USB adapter now would mean choosing a
/// package and a device-enumeration strategy against hardware nobody has connected,
/// and the first real device would very likely invalidate both. The seam is what is
/// worth building before the hardware arrives; the twenty lines behind it are not.
///
/// ## One document at a time
///
/// ESC/POS is a stream with no framing. Two documents written concurrently would
/// interleave into one unreadable page, so [send] serialises through [_queue]: a
/// second call waits for the first rather than racing it.
abstract class EscPosThermalPrinter implements ThermalPrinter {
  EscPosThermalPrinter({
    required this._endpoint,
    PrinterCapabilities capabilities = PrinterCapabilities.escPos80mm,
    PrintProfile? profile,
  }) : _capabilities = capabilities,
       _profile = profile ?? PrintProfile.forCapabilities(capabilities);

  final PrinterEndpoint _endpoint;
  final PrinterCapabilities _capabilities;
  final PrintProfile _profile;

  final StreamController<PrinterConnectionState> _states =
      StreamController<PrinterConnectionState>.broadcast();

  PrinterConnectionState _state = PrinterConnectionState.disconnected;

  /// Serialises print calls. Holds the tail of the queue, not a lock.
  Future<void> _queue = Future<void>.value();

  @override
  PrinterConnectionState get connectionState => _state;

  @override
  Stream<PrinterConnectionState> get connectionStates async* {
    // The current state first, so a widget built after a change does not sit on a
    // stale value while waiting for the next one.
    yield _state;
    yield* _states.stream;
  }

  @override
  PrinterEndpoint? get endpoint => _endpoint;

  @override
  PrinterCapabilities get capabilities => _capabilities;

  @override
  PrintProfile get profile => _profile;

  @override
  Future<Result<void>> connect() async {
    if (_state == PrinterConnectionState.connected ||
        _state == PrinterConnectionState.busy) {
      return const Ok<void>(null);
    }

    _moveTo(PrinterConnectionState.connecting);
    try {
      await openTransport();
      _moveTo(PrinterConnectionState.connected);
      return const Ok<void>(null);
    } catch (error) {
      _moveTo(PrinterConnectionState.disconnected);
      return Err<void>(
        PrinterFailure(
          'Could not reach the printer at ${_endpoint.description}.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) {
      return const Ok<void>(null);
    }
    try {
      await closeTransport();
      return const Ok<void>(null);
    } catch (error) {
      // Reported, but the printer is still treated as closed: a handle that failed
      // to close cleanly must not leave the application believing it can print.
      return Err<void>(
        PrinterFailure('Could not release the printer.', cause: error),
      );
    } finally {
      _moveTo(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<Result<void>> send(PrintJob job) {
    final Completer<Result<void>> completer = Completer<Result<void>>();

    // Chained onto the queue so documents leave in the order they were requested and
    // never interleave on the wire.
    _queue = _queue.then((void _) async {
      completer.complete(await _send(job));
    });

    return completer.future;
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _states.close();
  }

  // ---------------------------------------------------------------- transport ---

  /// Opens the underlying device or socket. Throws on failure.
  ///
  /// Implemented by a transport adapter. Throwing rather than returning a `Result` is
  /// deliberate: transport code deals in exceptions, and this base class is the single
  /// place that translates them into a [PrinterFailure], so no adapter has to get the
  /// message or the failure type right.
  Future<void> openTransport();

  /// Closes the underlying device or socket. Throws on failure.
  Future<void> closeTransport();

  /// Writes [job] to the printer. Throws on failure.
  ///
  /// Called with a whole encoded document in [PrintJob.bytes]. An adapter may chunk it
  /// — USB bulk transfers have a maximum packet size — but must not reorder or drop any
  /// of it, and must not add to it. The job is passed rather than a bare byte list so an
  /// adapter can log what it is sending, which is the difference between "a write
  /// failed" and "receipt 20260911-0001 failed after 812 bytes".
  Future<void> writeToTransport(PrintJob job);

  // ---------------------------------------------------------------- internals ---

  Future<Result<void>> _send(PrintJob job) async {
    if (job.isEmpty) {
      // An empty document is a fault above this class, not a successful print.
      return Err<void>(
        PrinterFailure('${job.title} came out empty and was not printed.'),
      );
    }

    final Result<void> opened = await connect();
    if (opened.isErr) {
      return opened;
    }

    _moveTo(PrinterConnectionState.busy);
    try {
      await writeToTransport(job);
      return const Ok<void>(null);
    } catch (error) {
      return Err<void>(
        PrinterFailure(
          'The printer stopped while printing ${job.title}. '
          'Check the paper and the connection.',
          cause: error,
        ),
      );
    } finally {
      // Back to connected, not disconnected: a document that failed mid-write does
      // not necessarily mean the cable came out, and the retry should not have to
      // reopen.
      _moveTo(PrinterConnectionState.connected);
    }
  }

  void _moveTo(PrinterConnectionState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }
}
