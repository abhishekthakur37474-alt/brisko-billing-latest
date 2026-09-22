import '../../../settings/domain/models/setting_keys.dart';
import 'print_profile.dart';
import 'printer_capabilities.dart';

/// The part of a [PrintProfile] the outlet is allowed to change.
///
/// ## Why this is not just `PrintProfile`
///
/// [PrintProfile] holds everything a document layout depends on, including things that
/// are not the operator's business: the paper width comes from the roll the printer
/// takes, the option indent and the rule characters are layout decisions this build has
/// made, and letting either be typed into a text field would let a receipt be
/// reconfigured into something no test covers.
///
/// What is here is the set of profile values that can be chosen honestly on a terminal
/// with no printer attached, and that a real printer might genuinely need corrected:
/// the font, a column count that disagrees with the font's arithmetic, whether and how
/// the roll is cut, how far it is fed first, and the three QR settings. Every one of
/// them is verifiable today, because it changes the bytes the encoder produces.
///
/// ## What is deliberately absent
///
/// No transport. There is no device name, no vendor or product id, no host, no port and
/// no pairing here, because this terminal has no printer connected and a stored address
/// would be a claim that it has. Choosing where the printer is belongs with the adapter
/// that can actually open it.
///
/// ## No defaults of its own
///
/// Every field is required, and the only way to obtain a starting value is
/// [PrintSettings.fromProfile]. The defaults therefore stay where they were already
/// written down — on [PrintProfile] — rather than being copied here and left to drift.
class PrintSettings {
  const PrintSettings({
    required this.font,
    required this.columnOverride,
    required this.cut,
    required this.feedLinesBeforeCut,
    required this.isQrEnabled,
    required this.qrModuleSize,
    required this.qrErrorCorrection,
  });

  /// The configurable part of [profile], as it stands.
  factory PrintSettings.fromProfile(PrintProfile profile) => PrintSettings(
    font: profile.font,
    columnOverride: profile.columnOverride,
    cut: profile.cut,
    feedLinesBeforeCut: profile.feedLinesBeforeCut,
    isQrEnabled: profile.canPrintQrCode,
    qrModuleSize: profile.qrModuleSize,
    qrErrorCorrection: profile.qrErrorCorrection,
  );

  /// What has been saved, over the values [fallback] already carries.
  ///
  /// [stored] is the settings table as text. A key that is absent, blank or corrupt
  /// falls back rather than failing: a terminal has to be able to print a bill even if
  /// one row of its configuration is unreadable, and the fallback is the profile the
  /// printer itself reports.
  factory PrintSettings.fromStored(
    Map<String, String?> stored, {
    required PrintProfile fallback,
  }) {
    final PrintSettings defaults = PrintSettings.fromProfile(fallback);

    return PrintSettings(
      font:
          _named<PrinterFont>(
            stored[SettingKeys.printerFont],
            PrinterFont.values,
          ) ??
          defaults.font,
      // Absent means "use the font's arithmetic", so an unreadable value cannot be
      // distinguished from a cleared one, and both mean the same thing.
      columnOverride: _count(stored[SettingKeys.printerColumnOverride]),
      cut:
          _named<PrintCut>(stored[SettingKeys.printerCut], PrintCut.values) ??
          defaults.cut,
      feedLinesBeforeCut:
          _count(stored[SettingKeys.printerFeedLinesBeforeCut]) ??
          defaults.feedLinesBeforeCut,
      isQrEnabled:
          _flag(stored[SettingKeys.printerQrEnabled]) ?? defaults.isQrEnabled,
      qrModuleSize:
          _count(stored[SettingKeys.printerQrModuleSize]) ??
          defaults.qrModuleSize,
      qrErrorCorrection:
          _named<QrErrorCorrection>(
            stored[SettingKeys.printerQrErrorCorrection],
            QrErrorCorrection.values,
          ) ??
          defaults.qrErrorCorrection,
    );
  }

  // ------------------------------------------------------------------ ranges ---

  /// Smallest feed before a cut or a tear.
  ///
  /// One rather than zero. The blade and the tear bar both sit above the print head,
  /// so a document that is not fed at all ends with its last line still inside the
  /// printer — on a bill, the total. `EscPosBuilder.cut` feeds even on a printer with
  /// no blade for exactly that reason, and a zero here would defeat it.
  static const int minFeedLinesBeforeCut = 1;

  /// Largest feed. `ESC d n` carries one byte, so this is the protocol's own ceiling.
  static const int maxFeedLinesBeforeCut = 255;

  /// Smallest QR module, in dots, from the `GS ( k` module-size command.
  static const int minQrModuleSize = 1;

  /// Largest QR module, in dots, from the same command.
  static const int maxQrModuleSize = 16;

  final PrinterFont font;

  /// Columns to print in, or `null` to use the font's arithmetic.
  final int? columnOverride;

  final PrintCut cut;

  final int feedLinesBeforeCut;

  /// Whether the printer's QR engine is used at all.
  final bool isQrEnabled;

  final int qrModuleSize;

  final QrErrorCorrection qrErrorCorrection;

  // -------------------------------------------------------------- validation ---

  /// Everything wrong with these settings for a printer with [capabilities].
  ///
  /// Empty when they are usable. Returned as a list rather than as the first problem so
  /// the operator can fix a form in one pass instead of one message at a time.
  ///
  /// Each rule comes from something already written down: the column bounds from the
  /// font's own arithmetic and from the indent a document needs inside it, the feed and
  /// module bounds from the ESC/POS commands, and the cut and QR rules from what the
  /// printer says it can physically do.
  List<String> problems(PrinterCapabilities capabilities) {
    final PrintProfile reference = PrintProfile.forCapabilities(capabilities);
    final int fontColumns = font.columnsOn(capabilities.paperWidth);
    final int minColumns = reference.optionIndent + 1;

    final List<String> problems = <String>[];

    final int? columns = columnOverride;
    if (columns != null && (columns < minColumns || columns > fontColumns)) {
      problems.add(
        'Columns must be between $minColumns and $fontColumns for '
        '${font.label} on ${capabilities.paperWidth.label} paper, or left '
        'blank to use $fontColumns',
      );
    }

    if (feedLinesBeforeCut < minFeedLinesBeforeCut ||
        feedLinesBeforeCut > maxFeedLinesBeforeCut) {
      problems.add(
        'Feed before cut must be between $minFeedLinesBeforeCut and '
        '$maxFeedLinesBeforeCut lines',
      );
    }

    if (cut.isCut && !capabilities.hasAutoCutter) {
      problems.add(
        'This printer has no cutter, so the cut must be set to none and the '
        'paper torn off by hand',
      );
    }

    if (isQrEnabled && !capabilities.supportsQrCode) {
      problems.add(
        'This printer has no QR engine, so the payment QR cannot be printed',
      );
    }

    if (qrModuleSize < minQrModuleSize || qrModuleSize > maxQrModuleSize) {
      problems.add(
        'QR module size must be between $minQrModuleSize and $maxQrModuleSize '
        'dots',
      );
    }

    return problems;
  }

  /// True when these settings can be used on a printer with [capabilities].
  bool isValidFor(PrinterCapabilities capabilities) =>
      problems(capabilities).isEmpty;

  // ----------------------------------------------------------------- applying ---

  /// [base] with these settings applied.
  ///
  /// The paper, the indent and the rule characters are carried through untouched,
  /// because they are not the operator's to change.
  PrintProfile applyTo(PrintProfile base) => base.copyWith(
    font: font,
    columnOverride: columnOverride,
    clearColumnOverride: columnOverride == null,
    cut: cut,
    canPrintQrCode: isQrEnabled,
    feedLinesBeforeCut: feedLinesBeforeCut,
    qrModuleSize: qrModuleSize,
    qrErrorCorrection: qrErrorCorrection,
  );

  /// These settings as rows for the settings table.
  ///
  /// A `null` value means the key is removed, which is how "use the font's arithmetic"
  /// is stored: an absent row rather than a sentinel number.
  Map<String, String?> toStored() => <String, String?>{
    SettingKeys.printerFont: font.name,
    SettingKeys.printerColumnOverride: columnOverride?.toString(),
    SettingKeys.printerCut: cut.name,
    SettingKeys.printerFeedLinesBeforeCut: feedLinesBeforeCut.toString(),
    SettingKeys.printerQrEnabled: isQrEnabled ? 'true' : 'false',
    SettingKeys.printerQrModuleSize: qrModuleSize.toString(),
    SettingKeys.printerQrErrorCorrection: qrErrorCorrection.name,
  };

  PrintSettings copyWith({
    PrinterFont? font,
    int? columnOverride,
    bool clearColumnOverride = false,
    PrintCut? cut,
    int? feedLinesBeforeCut,
    bool? isQrEnabled,
    int? qrModuleSize,
    QrErrorCorrection? qrErrorCorrection,
  }) {
    return PrintSettings(
      font: font ?? this.font,
      columnOverride: clearColumnOverride
          ? null
          : columnOverride ?? this.columnOverride,
      cut: cut ?? this.cut,
      feedLinesBeforeCut: feedLinesBeforeCut ?? this.feedLinesBeforeCut,
      isQrEnabled: isQrEnabled ?? this.isQrEnabled,
      qrModuleSize: qrModuleSize ?? this.qrModuleSize,
      qrErrorCorrection: qrErrorCorrection ?? this.qrErrorCorrection,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrintSettings &&
      other.font == font &&
      other.columnOverride == columnOverride &&
      other.cut == cut &&
      other.feedLinesBeforeCut == feedLinesBeforeCut &&
      other.isQrEnabled == isQrEnabled &&
      other.qrModuleSize == qrModuleSize &&
      other.qrErrorCorrection == qrErrorCorrection;

  @override
  int get hashCode => Object.hash(
    font,
    columnOverride,
    cut,
    feedLinesBeforeCut,
    isQrEnabled,
    qrModuleSize,
    qrErrorCorrection,
  );

  @override
  String toString() =>
      'PrintSettings(${font.label}, columns: ${columnOverride ?? 'font'}, '
      'cut: ${cut.name}, feed: $feedLinesBeforeCut, qr: $isQrEnabled)';

  // --------------------------------------------------------------- internals ---

  /// The enum value in [values] whose name is [stored], or `null`.
  ///
  /// Enums are stored by name, so reordering a declaration cannot silently change a
  /// saved setting. An unrecognised name reads as absent rather than throwing: a value
  /// written by a later build should fall back, not stop the till.
  static T? _named<T extends Enum>(String? stored, List<T> values) {
    if (stored == null) {
      return null;
    }
    for (final T value in values) {
      if (value.name == stored) {
        return value;
      }
    }
    return null;
  }

  /// [stored] as a count, or `null` when it is absent or not a whole number.
  ///
  /// A count of dots, lines or characters. Nothing on this path is an amount: see
  /// `Money` for the one type that carries those, and note that no figure from this
  /// file ever reaches an amount row.
  static int? _count(String? stored) =>
      stored == null ? null : int.tryParse(stored);

  /// [stored] as a flag. Anything other than the stored value `true` is false, which is
  /// the same reading `SettingsRepository.readBool` gives.
  static bool? _flag(String? stored) =>
      stored == null ? null : stored == 'true';
}
