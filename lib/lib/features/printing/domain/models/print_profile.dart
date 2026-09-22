import 'paper_width.dart';
import 'printer_capabilities.dart';

/// The character grid a thermal printer prints in.
///
/// ## Why the font is part of the layout budget
///
/// An 80mm printer does not have "48 columns". It has a 72mm printable area, 576 dots
/// at 203dpi, and a font that is some number of dots wide. Font A is 12 dots and gives
/// 48 columns; Font B is 9 dots and gives 64. The column count is therefore a
/// consequence of two decisions, and writing 48 into a layout hard-codes both of them
/// while recording neither.
///
/// Naming the font makes the arithmetic visible, and it makes the one thing that is
/// genuinely uncertain before the hardware arrives — whether the device really prints
/// 48 columns of Font A — a value that can be corrected in one place.
enum PrinterFont {
  /// 12 dots wide. The default on every ESC/POS printer, and what this build targets.
  fontA(dotWidth: 12, selector: 0, label: 'Font A'),

  /// 9 dots wide. Narrower glyphs, more columns, harder to read across a counter.
  fontB(dotWidth: 9, selector: 1, label: 'Font B');

  const PrinterFont({
    required this.dotWidth,
    required this.selector,
    required this.label,
  });

  /// Width of one character cell in dots.
  final int dotWidth;

  /// Value carried by the `ESC M n` font-select command.
  final int selector;

  final String label;

  /// Characters this font fits across [paper]. Integer division, so a partial
  /// column is not counted as usable.
  int columnsOn(PaperWidth paper) => paper.printableDots ~/ dotWidth;
}

/// How a document is separated from the next one.
enum PrintCut {
  /// Cut the roll through. The paper falls free.
  full,

  /// Cut all but a tab, so the document stays attached until it is torn off.
  partial,

  /// Do not send a cut command at all.
  ///
  /// For a printer with no blade. The paper is fed instead, so the document clears
  /// the tear bar and can be torn by hand. Sending a cut to a printer that cannot
  /// cut is at best ignored and at worst mis-parsed.
  none;

  bool get isCut => this != PrintCut.none;

  /// How the choice reads on the settings screen.
  ///
  /// Written here beside the behaviour rather than in the widget, so the words and the
  /// bytes they select cannot drift apart.
  String get label => switch (this) {
    PrintCut.full => 'Full cut',
    PrintCut.partial => 'Partial cut',
    PrintCut.none => 'No cut, tear by hand',
  };
}

/// Redundancy built into a QR symbol, as the ESC/POS levels L, M, Q and H.
///
/// Modelled as a domain value rather than as the command byte so that a layout
/// decision does not have to import the protocol. The builder maps it.
enum QrErrorCorrection {
  /// 7% recoverable. Smallest symbol, least tolerant of a scuffed roll.
  low,

  /// 15%. The usual choice for a printed payment code.
  medium,

  /// 25%.
  quartile,

  /// 30%. Largest symbol, most tolerant.
  high;

  /// How the level reads on the settings screen.
  ///
  /// The percentage is the useful part: it is what the operator is trading against the
  /// size of the printed symbol.
  String get label => switch (this) {
    QrErrorCorrection.low => 'L, 7% recoverable',
    QrErrorCorrection.medium => 'M, 15% recoverable',
    QrErrorCorrection.quartile => 'Q, 25% recoverable',
    QrErrorCorrection.high => 'H, 30% recoverable',
  };
}

/// Everything about a printer that a document layout depends on.
///
/// ## Why this exists
///
/// A receipt layout needs a dozen printer-specific facts: how many characters fit on a
/// line, how far an option is indented under its item, what a horizontal rule is drawn
/// with, how many lines to feed so the cutter does not take the total off the bottom of
/// the bill, how large a QR module should be, and whether the printer can cut or encode
/// a QR at all. Left as literals, those facts end up spread across the builder, the
/// formatter and the command table, and the receipt then quietly assumes a specific
/// device without ever naming it.
///
/// Gathered here, they become one value that can be inspected, tested and — when the
/// real printer is in hand and turns out to print 42 columns rather than 48 — corrected
/// in one line. Nothing in [escPos80mm] is speculative: every number is either from the
/// ESC/POS specification or a layout decision this build has made.
///
/// ## No printer model
///
/// There is no manufacturer, no model, no vendor id and no address here. This describes
/// a class of hardware — an 80mm ESC/POS printer with a cutter and a QR engine — which
/// is what the outlet has decided to buy and all that a layout can honestly assume
/// before one is connected.
class PrintProfile {
  const PrintProfile({
    this.paper = PaperWidth.mm80,
    this.font = PrinterFont.fontA,
    this.columnOverride,
    this.cut = PrintCut.full,
    this.canPrintQrCode = true,
    this.canPrintGraphics = true,
    this.optionIndent = 2,
    this.feedLinesBeforeCut = 4,
    this.qrModuleSize = 6,
    this.qrErrorCorrection = QrErrorCorrection.medium,
    this.rule = '-',
    this.emphasisRule = '=',
  });

  /// Derives a profile from what a printer says it can do.
  ///
  /// The capabilities are the hardware facts; the profile is the layout built on top of
  /// them. Deriving one from the other means the two cannot disagree: a printer with no
  /// blade gets [PrintCut.none] rather than a cut command it would ignore, and a printer
  /// with no QR engine gets a receipt with no QR block rather than a page of garbage.
  factory PrintProfile.forCapabilities(
    PrinterCapabilities capabilities, {
    PrinterFont font = PrinterFont.fontA,
    int? columnOverride,
  }) {
    return PrintProfile(
      paper: capabilities.paperWidth,
      font: font,
      columnOverride: columnOverride,
      cut: capabilities.hasAutoCutter ? PrintCut.full : PrintCut.none,
      canPrintQrCode: capabilities.supportsQrCode,
      canPrintGraphics: capabilities.supportsGraphics,
    );
  }

  /// The profile every document in this build is laid out for.
  ///
  /// 80mm paper, Font A, 48 columns, an auto cutter and a native QR engine: the
  /// hardware the outlet has selected.
  static const PrintProfile escPos80mm = PrintProfile();

  final PaperWidth paper;

  final PrinterFont font;

  /// Columns to use instead of the arithmetic, when a real printer disagrees with it.
  ///
  /// Deliberately the only escape hatch in this class, and deliberately explicit. Some
  /// 80mm printers reserve a margin and print 47 or 42 columns of Font A, which is
  /// discovered by printing the test page's ruler and counting. When that happens this
  /// is the one value that changes, and every document narrows with it.
  final int? columnOverride;

  final PrintCut cut;

  /// True when the printer renders a QR from data rather than needing a bitmap.
  ///
  /// False suppresses the receipt's payment block entirely. A half-printed QR is worse
  /// than none: it would scan to a corrupted payment URI.
  final bool canPrintQrCode;

  /// True when the printer has a raster graphics mode, which a bitmap logo needs.
  ///
  /// False suppresses the receipt's logo entirely, the same way [canPrintQrCode]
  /// suppresses the QR: a printer with no graphics mode gets a header with no logo
  /// rather than a run of raster bytes printed as text.
  final bool canPrintGraphics;

  /// Spaces an option or a note is indented beneath its item.
  final int optionIndent;

  /// Lines fed before cutting, so the printed area clears the blade.
  ///
  /// The cutter sits above the print head. Without this the last few lines are cut
  /// off, which on a bill is the total and on a slip is the last item.
  final int feedLinesBeforeCut;

  /// Size of one QR module in dots, 1 to 16.
  ///
  /// Six gives roughly a 25mm symbol on 80mm paper: comfortably scannable, without
  /// spending a third of the roll on it.
  final int qrModuleSize;

  final QrErrorCorrection qrErrorCorrection;

  /// Character a horizontal rule is drawn with.
  final String rule;

  /// Character a rule that frames the total is drawn with.
  final String emphasisRule;

  /// Characters available on one printed line. The layout budget.
  int get columns => columnOverride ?? font.columnsOn(paper);

  /// True when this profile's column count is the font's own arithmetic.
  bool get usesFontColumns => columnOverride == null;

  /// Width available inside an item's indent, for an option or a note.
  int get indentedColumns => columns - optionIndent;

  PrintProfile copyWith({
    PaperWidth? paper,
    PrinterFont? font,
    int? columnOverride,
    PrintCut? cut,
    bool? canPrintQrCode,
    bool? canPrintGraphics,
    int? optionIndent,
    int? feedLinesBeforeCut,
    int? qrModuleSize,
    QrErrorCorrection? qrErrorCorrection,
    String? rule,
    String? emphasisRule,
    bool clearColumnOverride = false,
  }) {
    return PrintProfile(
      paper: paper ?? this.paper,
      font: font ?? this.font,
      columnOverride: clearColumnOverride
          ? null
          : columnOverride ?? this.columnOverride,
      cut: cut ?? this.cut,
      canPrintQrCode: canPrintQrCode ?? this.canPrintQrCode,
      canPrintGraphics: canPrintGraphics ?? this.canPrintGraphics,
      optionIndent: optionIndent ?? this.optionIndent,
      feedLinesBeforeCut: feedLinesBeforeCut ?? this.feedLinesBeforeCut,
      qrModuleSize: qrModuleSize ?? this.qrModuleSize,
      qrErrorCorrection: qrErrorCorrection ?? this.qrErrorCorrection,
      rule: rule ?? this.rule,
      emphasisRule: emphasisRule ?? this.emphasisRule,
    );
  }

  @override
  String toString() =>
      'PrintProfile(${paper.label}, ${font.label}, $columns columns, '
      'cut: ${cut.name}, qr: $canPrintQrCode)';
}
