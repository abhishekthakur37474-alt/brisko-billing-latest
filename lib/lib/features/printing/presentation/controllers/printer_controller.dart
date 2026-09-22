import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../settings/domain/repositories/settings_repository.dart';
import '../../domain/models/paper_width.dart';
import '../../domain/models/print_job.dart';
import '../../domain/models/printer_connection.dart';
import '../../domain/models/printer_connection_settings.dart';
import '../../domain/models/printer_status.dart';
import '../../domain/printers/active_printer.dart';
import '../../domain/services/active_print_profile.dart';
import '../../domain/services/print_service.dart';

/// Which printer this terminal is bound to, and whether it works.
///
/// ## Why the printer has its own controller and its own Save
///
/// The rest of the Settings screen is one configuration saved in one transaction, for a
/// good reason: half a new address above an old GSTIN would go out on a tax invoice.
/// A printer binding is not part of that document. It is a statement about a device on
/// the counter, and it has something the other sections do not — an immediate way to
/// check it, which is [testPrint].
///
/// Binding it to the screen-wide Save would mean the operator could not try a corrected
/// address without also committing whatever they had typed into the business fields, and
/// could not try it at all without leaving and returning. So this section saves and
/// applies on its own, and the two Saves are separate because they answer to different
/// things.
///
/// ## What it never does
///
/// It does not print a bill, does not read an order, and holds no amount. `Money` does
/// not appear in this file, and the only integer it parses is a TCP port. The test page it
/// sends carries no payment code by construction — see `PrinterTestPage`.
///
/// ## Applying is not connecting
///
/// [save] writes the rows, then hands the settings to [ActivePrinter], which rebuilds the
/// transport. On this build that produces a printer which reports honestly that it cannot
/// be reached, because no transport adapter ships. Saving therefore always succeeds and
/// printing may still fail, which is exactly the distinction the operator needs.
class PrinterController extends ChangeNotifier {
  PrinterController({
    required this._settings,
    required ActivePrinter printer,
    required this._printService,
    required this._printProfile,
  }) : _printer = printer,
       _saved = printer.connectionSettings {
    _resetDraft();
  }

  final SettingsRepository _settings;
  final ActivePrinter _printer;
  final PrintService _printService;

  /// The layout, so that a change of roll reaches the encoder.
  ///
  /// The only reason this controller touches the profile at all. Choosing a font or a
  /// column count belongs to the Printing section beside it; changing the paper is a fact
  /// about the device, and the encoder has to follow it or documents come out laid out for
  /// a roll the printer does not have.
  final ActivePrintProfile _printProfile;

  /// What is on disk, as last read or last written. The baseline for "changed".
  PrinterConnectionSettings _saved;

  // The draft. The port is held as text so that "not a number" is a message beside the
  // field rather than a silently discarded keystroke.
  bool _isEnabled = false;
  PrinterTransport? _transport;
  String _address = '';
  String _port = '';
  String _deviceName = '';
  String _label = '';
  PaperWidth _paperWidth = PrinterConnectionSettings.defaultPaperWidth;

  bool _isSaving = false;
  bool _isTesting = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _testMessage;
  bool _didTestSucceed = false;

  // -------------------------------------------------------------------- state ---

  /// The combined printer state: what is saved, what the transport reports, and what this
  /// build can support.
  PrinterStatus get status => _printer.status;

  /// Connection changes, for an indicator that follows a reconfiguration.
  Stream<PrinterConnectionState> get connectionStates =>
      _printer.connectionStates;

  bool get isEnabled => _isEnabled;

  PrinterTransport? get transport => _transport;

  String get address => _address;

  String get port => _port;

  String get deviceName => _deviceName;

  String get label => _label;

  PaperWidth get paperWidth => _paperWidth;

  bool get isSaving => _isSaving;

  bool get isTesting => _isTesting;

  /// Why the last save was refused, or `null`.
  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// What the last test print did, or `null` when none has been attempted.
  ///
  /// Always a statement about what happened, never a reassurance. A test page on a
  /// terminal with no transport reports that it could not be sent, and says why.
  String? get testMessage => _testMessage;

  /// True when the last test page reached the printer.
  bool get didTestSucceed => _didTestSucceed;

  /// True when the draft differs from what is stored.
  bool get isDirty => _draftOrNull() != _saved;

  /// Everything wrong with the draft, in the order the form shows it.
  ///
  /// A port that is not a number is reported here as well as beside the field, so Save
  /// cannot be pressed past it.
  List<String> get problems {
    final PrinterConnectionSettings? draft = _draftOrNull();
    if (draft == null) {
      return const <String>['The port must be a whole number'];
    }
    return draft.problems;
  }

  bool get isValid => problems.isEmpty;

  /// True when Save should do something.
  bool get canSave => !_isSaving && isValid && isDirty;

  /// Why the address is refused, or `null`.
  String? get addressError => _firstProblemMentioning('address');

  /// Why the port is refused, or `null`.
  String? get portError {
    if (_port.trim().isNotEmpty && int.tryParse(_port.trim()) == null) {
      return 'Enter a whole number, or leave blank to use '
          '${PrinterEndpoint.defaultLanPort}';
    }
    return _firstProblemMentioning('port');
  }

  /// Why the printer name is refused, or `null`.
  String? get labelError => _firstProblemMentioning('printer name');

  /// Why a transport has to be chosen, or `null`.
  String? get transportError => _firstProblemMentioning('connected by');

  /// True when the network fields are the ones that matter.
  bool get isNetworked => _transport?.isNetworked ?? false;

  /// True when the USB fields are the ones that matter.
  bool get isUsb => _transport == PrinterTransport.usb;

  // -------------------------------------------------------------------- intents ---

  void setEnabled({required bool isEnabled}) =>
      _edit(() => _isEnabled = isEnabled, from: _isEnabled, to: isEnabled);

  void selectTransport(PrinterTransport transport) =>
      _edit(() => _transport = transport, from: _transport, to: transport);

  void editAddress(String value) =>
      _edit(() => _address = value, from: _address, to: value);

  void editPort(String value) =>
      _edit(() => _port = value, from: _port, to: value);

  void editDeviceName(String value) =>
      _edit(() => _deviceName = value, from: _deviceName, to: value);

  void editLabel(String value) =>
      _edit(() => _label = value, from: _label, to: value);

  void selectPaperWidth(PaperWidth width) =>
      _edit(() => _paperWidth = width, from: _paperWidth, to: width);

  /// Abandons unsaved edits and returns the form to what is stored.
  void discardChanges() {
    _resetDraft();
    _errorMessage = null;
    _notify();
  }

  // --------------------------------------------------------------------- saving ---

  /// Writes the printer binding, then points this terminal at it.
  ///
  /// Returns true when the rows are on disk. The binding is applied only after the write
  /// commits, so a terminal that failed to save is still using — and still reporting —
  /// the printer it was using before.
  ///
  /// Saving does not connect and does not claim to. What it produces is a printer object
  /// whose status the screen then shows, which on a build with no transport adapter says
  /// so plainly.
  Future<bool> save() async {
    if (_isSaving) {
      return false;
    }
    if (!isDirty) {
      // Already stored. Reported as success, because pressing Save twice must not tell
      // the operator that the second press failed.
      return true;
    }
    if (!isValid) {
      _errorMessage = 'The printer was not saved: ${problems.join('. ')}.';
      _notify();
      return false;
    }

    final PrinterConnectionSettings draft = _draftOrNull()!;

    _isSaving = true;
    _errorMessage = null;
    // A test result from the previous printer would be read as belonging to this one.
    _testMessage = null;
    _didTestSucceed = false;
    _notify();

    final Result<void> written = await _settings.writeAll(draft.toStored());
    final AppFailure? failure = written.failureOrNull;
    if (failure != null) {
      // Nothing applied and nothing reset: the terminal is still on the previous printer
      // and the form still holds the edits, so Save can be pressed again.
      _isSaving = false;
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    _saved = draft;

    // Only now. Until the write committed, this terminal was using the old binding and
    // saying so.
    final Result<void> applied = await _printer.apply(draft);

    // And the layout follows the paper, so a roll width chosen above changes the next
    // document rather than the next launch.
    _printProfile.retargetTo(draft.capabilities);

    _isSaving = false;
    // A printer that would not release cleanly is worth reporting, but the new binding is
    // in force regardless: refusing a corrected address because the previous device
    // misbehaved would leave the operator with no way forward.
    _errorMessage = applied.failureOrNull?.message;
    _resetDraft();
    _notify();
    return true;
  }

  // ----------------------------------------------------------------- test print ---

  /// Sends a short test page through the same printer real bills use.
  ///
  /// ## Why it goes through [PrintService] and not straight to the printer
  ///
  /// A test that took its own shortcut to the transport would prove the transport and
  /// nothing else. This one is encoded by the same encoder, for the same profile, and
  /// handed to the same printer as a receipt, so a test page that comes out correctly is
  /// evidence about the path a bill actually takes — including the column count, the font
  /// and the cut.
  ///
  /// ## It reports what happened
  ///
  /// On a terminal with no transport, this fails and says why. It does not report a
  /// success that did not occur: a green tick beside a printer that cannot print would
  /// be discovered at the counter, in front of a customer.
  Future<bool> testPrint() async {
    if (_isTesting) {
      return false;
    }

    _isTesting = true;
    _testMessage = null;
    _didTestSucceed = false;
    _notify();

    final Result<PrintJob> printed = await _printService.printTestPage();

    _isTesting = false;
    return printed.fold<bool>(
      onOk: (PrintJob job) {
        _didTestSucceed = true;
        _testMessage =
            'Test page sent to ${status.description}. Check that the ruler '
            'line is not wrapped and that the paper cut where it should.';
        _notify();
        return true;
      },
      onErr: (AppFailure failure) {
        _didTestSucceed = false;
        // The printer's own words. It knows whether nothing is configured, whether this
        // build has no transport for what is configured, or whether the device did not
        // answer, and those need three different actions.
        _testMessage = 'The test page could not be printed. ${failure.message}';
        _notify();
        return false;
      },
    );
  }

  /// Clears the test result, leaving the configuration alone.
  void dismissTestResult() {
    if (_testMessage == null) {
      return;
    }
    _testMessage = null;
    _didTestSucceed = false;
    _notify();
  }

  // ------------------------------------------------------------------ internals ---

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// The draft as it will be stored, or `null` when the port is not a number.
  PrinterConnectionSettings? _draftOrNull() {
    int? port;
    final String typed = _port.trim();
    if (typed.isNotEmpty) {
      port = int.tryParse(typed);
      if (port == null) {
        return null;
      }
    }

    return PrinterConnectionSettings(
      isEnabled: _isEnabled,
      transport: _transport,
      address: _stored(_address),
      port: port,
      deviceName: _stored(_deviceName),
      label: _stored(_label),
      paperWidth: _paperWidth,
    );
  }

  void _resetDraft() {
    _isEnabled = _saved.isEnabled;
    _transport = _saved.transport;
    _address = _saved.address ?? '';
    _port = _saved.port?.toString() ?? '';
    _deviceName = _saved.deviceName ?? '';
    _label = _saved.label ?? '';
    _paperWidth = _saved.paperWidth;
  }

  void _edit(
    void Function() apply, {
    required Object? from,
    required Object? to,
  }) {
    if (from == to) {
      return;
    }
    apply();
    _errorMessage = null;
    _notify();
  }

  /// The problem mentioning [fragment], for a message beside one field.
  String? _firstProblemMentioning(String fragment) {
    for (final String problem in problems) {
      if (problem.contains(fragment)) {
        return problem;
      }
    }
    return null;
  }

  void _notify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  /// [value] as it goes into the table, or `null` when it holds nothing.
  static String? _stored(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
