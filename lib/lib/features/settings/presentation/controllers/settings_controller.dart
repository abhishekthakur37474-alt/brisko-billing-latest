import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../billing/domain/models/gst_rate.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../printing/domain/models/print_profile.dart';
import '../../../printing/domain/models/print_settings.dart';
import '../../../printing/domain/models/printer_capabilities.dart';
import '../../../printing/domain/services/active_print_profile.dart';
import '../../domain/active_pos_settings.dart';
import '../../domain/models/gstin.dart';
import '../../domain/models/pos_settings.dart';
import '../../domain/repositories/settings_repository.dart';

/// Where the Settings screen stands.
///
/// Five states rather than a pair of booleans, because the screen has to look different
/// in each: nothing to show yet, a form, a form that is being written, a form that has
/// just been written, and a message with a way to try again.
enum SettingsStatus {
  /// Reading the stored configuration. No form yet.
  loading,

  /// The form is showing what is stored.
  loaded,

  /// A save is in flight. The form is visible but must not be submitted again.
  saving,

  /// The last save committed, and nothing has been edited since.
  saved,

  /// Something failed. [SettingsController.errorMessage] says what, and the operator
  /// can try again.
  error,
}

/// Holds the Settings screen: the form, what is wrong with it, and saving it.
///
/// ## The draft is here, not in the widgets
///
/// Every field the operator can change is a value on this controller. The widgets own
/// `TextEditingController`s for the cursor and nothing else, and they report each
/// keystroke through an `edit…` method. That is what makes the two guarantees the
/// requirement asks for possible at all: a failed save leaves the typing exactly where
/// it was, because it was never in a widget that got rebuilt, and validation messages
/// are computed in one place instead of once per field.
///
/// ## What a save does, in order
///
/// Validate, then write every key in one transaction, then — only if that committed —
/// update the copies held in memory so the next bill and the next receipt use the new
/// configuration. Nothing is applied before the write succeeds, so the terminal never
/// runs on a configuration that is not on disk.
///
/// ## No money, and no printer
///
/// There is no amount and no discount anywhere in this file, and nothing here constructs
/// one. The GST rate is the only value on this screen that a bill's arithmetic reads, and
/// it is an integer count of basis points chosen from a list — not an amount, not typed,
/// and not parseable into a wrong number. It reaches a bill only through `BillTotals`, and
/// only a bill settled after it is saved.
///
/// There is also no connection, no address and no device: choosing a printer's layout does
/// not claim that a printer is attached.
class SettingsController extends ChangeNotifier {
  SettingsController({
    required this._settings,
    required ActivePrintProfile printProfile,
    required this._activeSettings,
  }) : _printProfile = printProfile,
       _saved = PosSettings.unconfigured,
       // The printer's own values, so the form shows the layout in force before anything
       // has been configured rather than a set of literals copied into this file.
       _savedPrint = PrintSettings.fromProfile(printProfile.baseProfile) {
    _resetDraft();
  }

  final SettingsRepository _settings;
  final ActivePrintProfile _printProfile;
  final ActivePosSettings _activeSettings;

  /// What is on disk, as last read or last written. The baseline for "changed".
  PosSettings _saved;
  PrintSettings _savedPrint;

  SettingsStatus _status = SettingsStatus.loading;
  String? _errorMessage;
  bool _hasLoaded = false;
  bool _isDisposed = false;

  /// Set while a read is in flight, so two overlapping reads cannot interleave and
  /// leave the form showing the earlier one's result.
  bool _isReading = false;

  // The draft. Text is held as typed, including whitespace, so nothing the operator
  // sees changes under the cursor. Trimming happens once, on the way to storage.
  String _businessName = '';
  String _businessAddress = '';
  String _businessPhone = '';
  String _gstin = '';
  String _receiptHeader = '';
  String _receiptFooter = '';
  String _feedbackUrl = '';
  String _upiVpa = '';
  String _upiPayeeName = '';
  OrderType _defaultOrderType = PosSettings.fallbackOrderType;
  bool _printKitchenSlip = true;
  bool _askCustomerDetails = true;

  // A choice from a fixed list, not a typed value, so there is no draft text to validate
  // and no way to save a rate nobody meant.
  GstRate _gstRate = GstRate.zero;

  // Printer layout. The three numeric values are held as text so that "not a number"
  // is a message beside the field rather than a silently discarded keystroke.
  PrinterFont _font = PrinterFont.fontA;
  String _columnOverride = '';
  PrintCut _cut = PrintCut.full;
  String _feedLinesBeforeCut = '';
  bool _isQrEnabled = true;
  String _qrModuleSize = '';
  QrErrorCorrection _qrErrorCorrection = QrErrorCorrection.medium;

  // -------------------------------------------------------------------- state ---

  SettingsStatus get status => _status;

  bool get isLoading => _status == SettingsStatus.loading;

  bool get isSaving => _status == SettingsStatus.saving;

  /// True when the last save committed and nothing has been edited since.
  bool get isSaved => _status == SettingsStatus.saved;

  bool get hasError => _errorMessage != null;

  String? get errorMessage => _errorMessage;

  /// True once the stored configuration has been read successfully.
  ///
  /// Distinguishes "nothing configured yet" from "not read yet", which is the difference
  /// between showing an empty form and showing a blank screen.
  bool get hasLoaded => _hasLoaded;

  /// True when the draft differs from what is stored.
  bool get isDirty => _draft() != _saved || _printDraftOrNull() != _savedPrint;

  /// What the printer this terminal is laid out for can physically do.
  PrinterCapabilities get capabilities => _printProfile.capabilities;

  /// The layout every document is currently encoded for.
  PrintProfile get activeProfile => _printProfile.profile;

  /// Columns the selected font fits on this paper, which is what leaving the column
  /// override blank means.
  int get fontColumns => _font.columnsOn(capabilities.paperWidth);

  // -------------------------------------------------------------------- draft ---

  String get businessName => _businessName;

  String get businessAddress => _businessAddress;

  String get businessPhone => _businessPhone;

  String get gstin => _gstin;

  String get receiptHeader => _receiptHeader;

  String get receiptFooter => _receiptFooter;

  String get feedbackUrl => _feedbackUrl;

  String get upiVpa => _upiVpa;

  String get upiPayeeName => _upiPayeeName;

  OrderType get defaultOrderType => _defaultOrderType;

  bool get printKitchenSlip => _printKitchenSlip;

  bool get askCustomerDetails => _askCustomerDetails;

  /// The GST rate new bills will be charged at once this form is saved.
  GstRate get gstRate => _gstRate;

  PrinterFont get font => _font;

  String get columnOverride => _columnOverride;

  PrintCut get cut => _cut;

  String get feedLinesBeforeCut => _feedLinesBeforeCut;

  bool get isQrEnabled => _isQrEnabled;

  String get qrModuleSize => _qrModuleSize;

  QrErrorCorrection get qrErrorCorrection => _qrErrorCorrection;

  // --------------------------------------------------------------- validation ---

  /// Why the GSTIN is refused, or `null` when it is acceptable.
  ///
  /// Blank is acceptable: an outlet that is not registered, or has not been given its
  /// number yet, has no GSTIN to print and the receipt omits the line.
  String? get gstinError =>
      Gstin.isAcceptable(_gstin) ? null : Gstin.requirement;

  /// Why the column override is refused, or `null`.
  ///
  /// Blank is acceptable and means "use the font's arithmetic", which is the normal
  /// case. A value is only entered when a real printer has been seen to disagree with
  /// it.
  String? get columnOverrideError {
    if (_isBlank(_columnOverride)) {
      return null;
    }
    if (_parse(_columnOverride) == null) {
      return 'Enter a whole number of columns, or leave blank for $fontColumns';
    }
    return _firstProblemMentioning('Columns');
  }

  String? get feedLinesError {
    if (_parse(_feedLinesBeforeCut) == null) {
      return 'Enter a whole number of lines';
    }
    return _firstProblemMentioning('Feed');
  }

  String? get qrModuleSizeError {
    if (_parse(_qrModuleSize) == null) {
      return 'Enter a whole number of dots';
    }
    return _firstProblemMentioning('QR module size');
  }

  /// Why the cut setting is refused, or `null`.
  String? get cutError => _firstProblemMentioning('cutter');

  /// Why the QR cannot be enabled, or `null`.
  String? get qrEnabledError => _firstProblemMentioning('QR engine');

  /// Everything the printer section refuses, in the order it is shown.
  ///
  /// Empty when the printer settings are usable. Read by the screen for a summary and
  /// by [canSave].
  List<String> get printerProblems {
    final PrintSettings? draft = _printDraftOrNull();
    if (draft == null) {
      return const <String>['Every printer value must be a whole number'];
    }
    return draft.problems(capabilities);
  }

  /// True when nothing on the form is refused.
  bool get isValid => gstinError == null && printerProblems.isEmpty;

  /// True when Save should do something.
  ///
  /// False while a save is in flight, which is the first of the two guards against a
  /// double submission; the second is in [save] itself, so a caller that is not a button
  /// cannot get past it either.
  bool get canSave => _hasLoaded && !isSaving && isValid && isDirty;

  // ------------------------------------------------------------------- reading ---

  /// Reads the stored configuration into the form.
  ///
  /// Safe to call again: a failed read leaves [status] at [SettingsStatus.error] with a
  /// message, and calling this is the retry.
  Future<void> load() async {
    if (_isReading) {
      return;
    }
    _isReading = true;

    _status = SettingsStatus.loading;
    _errorMessage = null;
    _notify();

    final Result<Map<String, String?>> stored = await _settings.readAll();
    _isReading = false;

    final AppFailure? failure = stored.failureOrNull;
    if (failure != null) {
      // Deliberately not falling back to an empty form. A blank field beside a storage
      // error would look like an unconfigured outlet, and saving it would overwrite a
      // GSTIN that is on disk and merely unreadable at this moment.
      _status = SettingsStatus.error;
      _errorMessage = failure.message;
      _notify();
      return;
    }

    final Map<String, String?> values = stored.valueOrNull!;
    _saved = PosSettings.fromStored(values);
    _savedPrint = PrintSettings.fromStored(
      values,
      fallback: _printProfile.baseProfile,
    );

    _resetDraft();
    _hasLoaded = true;
    _status = SettingsStatus.loaded;
    _notify();
  }

  /// Retries whatever failed: the read, or the save.
  Future<void> retry() async {
    if (_hasLoaded && isDirty) {
      await save();
      return;
    }
    await load();
  }

  // ------------------------------------------------------------------- editing ---

  void editBusinessName(String value) =>
      _edit(() => _businessName = value, from: _businessName, to: value);

  void editBusinessAddress(String value) =>
      _edit(() => _businessAddress = value, from: _businessAddress, to: value);

  void editBusinessPhone(String value) =>
      _edit(() => _businessPhone = value, from: _businessPhone, to: value);

  void editGstin(String value) =>
      _edit(() => _gstin = value, from: _gstin, to: value);

  void editReceiptHeader(String value) =>
      _edit(() => _receiptHeader = value, from: _receiptHeader, to: value);

  void editReceiptFooter(String value) =>
      _edit(() => _receiptFooter = value, from: _receiptFooter, to: value);

  void editFeedbackUrl(String value) =>
      _edit(() => _feedbackUrl = value, from: _feedbackUrl, to: value);

  void editUpiVpa(String value) =>
      _edit(() => _upiVpa = value, from: _upiVpa, to: value);

  void editUpiPayeeName(String value) =>
      _edit(() => _upiPayeeName = value, from: _upiPayeeName, to: value);

  void selectDefaultOrderType(OrderType type) =>
      _edit(() => _defaultOrderType = type, from: _defaultOrderType, to: type);

  void setPrintKitchenSlip({required bool isEnabled}) => _edit(
    () => _printKitchenSlip = isEnabled,
    from: _printKitchenSlip,
    to: isEnabled,
  );

  void setAskCustomerDetails({required bool isEnabled}) => _edit(
    () => _askCustomerDetails = isEnabled,
    from: _askCustomerDetails,
    to: isEnabled,
  );

  /// Chooses the GST rate for bills settled after the next save.
  ///
  /// Ignores a rate outside 0–100%, which nothing on the screen can offer. Bills already
  /// settled are untouched whatever is chosen here: each one carries the rate it was
  /// charged at.
  void selectGstRate(GstRate rate) {
    if (!rate.isAcceptable) {
      return;
    }
    _edit(() => _gstRate = rate, from: _gstRate, to: rate);
  }

  void selectFont(PrinterFont font) =>
      _edit(() => _font = font, from: _font, to: font);

  void editColumnOverride(String value) =>
      _edit(() => _columnOverride = value, from: _columnOverride, to: value);

  void selectCut(PrintCut cut) => _edit(() => _cut = cut, from: _cut, to: cut);

  void editFeedLinesBeforeCut(String value) => _edit(
    () => _feedLinesBeforeCut = value,
    from: _feedLinesBeforeCut,
    to: value,
  );

  void setQrEnabled({required bool isEnabled}) =>
      _edit(() => _isQrEnabled = isEnabled, from: _isQrEnabled, to: isEnabled);

  void editQrModuleSize(String value) =>
      _edit(() => _qrModuleSize = value, from: _qrModuleSize, to: value);

  void selectQrErrorCorrection(QrErrorCorrection level) => _edit(
    () => _qrErrorCorrection = level,
    from: _qrErrorCorrection,
    to: level,
  );

  /// Abandons unsaved edits and returns the form to what is stored.
  void discardChanges() {
    if (!_hasLoaded) {
      return;
    }
    _resetDraft();
    _errorMessage = null;
    _status = SettingsStatus.loaded;
    _notify();
  }

  // -------------------------------------------------------------------- saving ---

  /// Writes the form, and applies it if the write commits.
  ///
  /// Returns true when the configuration is on disk. Returns false and leaves the draft
  /// untouched otherwise, whether it was refused by validation or by storage — so a
  /// failure never costs the operator their typing.
  Future<bool> save() async {
    if (isSaving || !_hasLoaded) {
      // The second of the two guards against a double submission. A save already in
      // flight owns the write; starting another would put two transactions in a race
      // over the same keys for no gain.
      return false;
    }

    if (!isDirty) {
      // The form already matches what is stored, so there is nothing to write. Reported
      // as success because it is one: pressing Save a second time must not tell the
      // operator that the second press failed.
      return true;
    }

    if (!isValid) {
      _status = SettingsStatus.error;
      _errorMessage = _refusalMessage();
      _notify();
      return false;
    }

    final PosSettings draft = _draft();
    final PrintSettings printDraft = _printDraftOrNull()!;

    _status = SettingsStatus.saving;
    _errorMessage = null;
    _notify();

    final Result<void> written = await _settings.writeAll(<String, String?>{
      ...draft.toStored(),
      ...printDraft.toStored(),
    });

    final AppFailure? failure = written.failureOrNull;
    if (failure != null) {
      // Nothing is applied and nothing is reset: what is on disk is still what was there
      // before, what is in memory still matches it, and the form still holds the edits so
      // the operator can press Save again.
      _status = SettingsStatus.error;
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    _saved = draft;
    _savedPrint = printDraft;

    // Only now. Until the write committed, the terminal was running the old
    // configuration and saying so.
    _activeSettings.apply(draft);
    _printProfile.apply(printDraft);

    // The draft is reset from what was stored, so a GSTIN typed in lower case is shown
    // back in the form exactly as it was saved.
    _resetDraft();
    _status = SettingsStatus.saved;
    _notify();
    return true;
  }

  // ----------------------------------------------------------------- internals ---

  /// The business and behaviour half of the form, as it will be stored.
  PosSettings _draft() => PosSettings(
    businessName: _stored(_businessName),
    businessAddress: _stored(_businessAddress),
    businessPhone: _stored(_businessPhone),
    // Stored upper-cased, which is the alphabet a GSTIN is defined in. An unacceptable
    // value never reaches here: [save] refuses first, and nothing rewrites it.
    gstin: _isBlank(_gstin) ? null : Gstin.tryNormalise(_gstin),
    receiptHeader: _stored(_receiptHeader),
    receiptFooter: _stored(_receiptFooter),
    feedbackUrl: _stored(_feedbackUrl),
    upiVpa: _stored(_upiVpa),
    upiPayeeName: _stored(_upiPayeeName),
    defaultOrderType: _defaultOrderType,
    gstRate: _gstRate,
    printKitchenSlip: _printKitchenSlip,
    askCustomerDetails: _askCustomerDetails,
  );

  /// The printer half of the form, or `null` when a number cannot be read.
  PrintSettings? _printDraftOrNull() {
    final int? feed = _parse(_feedLinesBeforeCut);
    final int? module = _parse(_qrModuleSize);
    if (feed == null || module == null) {
      return null;
    }

    // Blank is not a missing number; it is the choice to use the font's arithmetic.
    int? columns;
    if (!_isBlank(_columnOverride)) {
      columns = _parse(_columnOverride);
      if (columns == null) {
        return null;
      }
    }

    return PrintSettings(
      font: _font,
      columnOverride: columns,
      cut: _cut,
      feedLinesBeforeCut: feed,
      isQrEnabled: _isQrEnabled,
      qrModuleSize: module,
      qrErrorCorrection: _qrErrorCorrection,
    );
  }

  /// Puts the stored values back into the draft.
  void _resetDraft() {
    _businessName = _saved.businessName ?? '';
    _businessAddress = _saved.businessAddress ?? '';
    _businessPhone = _saved.businessPhone ?? '';
    _gstin = _saved.gstin ?? '';
    _receiptHeader = _saved.receiptHeader ?? '';
    _receiptFooter = _saved.receiptFooter ?? '';
    _feedbackUrl = _saved.feedbackUrl ?? '';
    _upiVpa = _saved.upiVpa ?? '';
    _upiPayeeName = _saved.upiPayeeName ?? '';
    _defaultOrderType = _saved.defaultOrderType;
    _gstRate = _saved.gstRate;
    _printKitchenSlip = _saved.printKitchenSlip;
    _askCustomerDetails = _saved.askCustomerDetails;

    _font = _savedPrint.font;
    _columnOverride = _savedPrint.columnOverride?.toString() ?? '';
    _cut = _savedPrint.cut;
    _feedLinesBeforeCut = _savedPrint.feedLinesBeforeCut.toString();
    _isQrEnabled = _savedPrint.isQrEnabled;
    _qrModuleSize = _savedPrint.qrModuleSize.toString();
    _qrErrorCorrection = _savedPrint.qrErrorCorrection;
  }

  /// Applies an edit, and drops the "saved" confirmation once anything changes.
  void _edit(
    void Function() apply, {
    required Object? from,
    required Object? to,
  }) {
    if (from == to) {
      return;
    }
    apply();
    // A stale confirmation beside a changed field would say the change is stored.
    if (_status == SettingsStatus.saved || _status == SettingsStatus.error) {
      _status = SettingsStatus.loaded;
      _errorMessage = null;
    }
    _notify();
  }

  /// The problem mentioning [fragment], for a message beside one field.
  String? _firstProblemMentioning(String fragment) {
    for (final String problem in printerProblems) {
      if (problem.contains(fragment)) {
        return problem;
      }
    }
    return null;
  }

  /// What the operator is told when Save is pressed on a form that cannot be stored.
  String _refusalMessage() {
    final List<String> problems = <String>[?gstinError, ...printerProblems];
    if (problems.isEmpty) {
      return 'These settings could not be saved.';
    }
    return 'These settings were not saved: ${problems.join('. ')}.';
  }

  /// [value] as it goes into the table, or `null` when it holds nothing.
  static String? _stored(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _isBlank(String value) => value.trim().isEmpty;

  /// [value] as a count, or `null` when it is not one.
  ///
  /// Columns, lines and dots. Never an amount: nothing on this screen touches money.
  static int? _parse(String value) => int.tryParse(value.trim());

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Notifies unless the controller has already been disposed.
  ///
  /// A read or a write can still be in flight when the operator navigates away from
  /// Settings, and notifying a disposed notifier is an error.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
