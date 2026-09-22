import 'paper_width.dart';

/// What a printer can physically do.
///
/// Read by the formatter, not by billing code. It exists so a document can be laid
/// out for the paper and the features actually present rather than for an assumed
/// model: a printer without a cutter should be fed extra paper for a manual tear
/// instead of being sent a cut command it will ignore.
///
/// [escPos80mm] describes the hardware the outlet has selected.
class PrinterCapabilities {
  const PrinterCapabilities({
    required this.paperWidth,
    required this.hasAutoCutter,
    required this.supportsQrCode,
    this.supportsGraphics = false,
    this.isColour = false,
  });

  /// The selected hardware: 80mm, ESC/POS, auto cutter, native QR, raster graphics,
  /// monochrome.
  ///
  /// Graphics are enabled because the outlet's printer renders the QR family of
  /// commands correctly on the physical roll, and the raster bit image (`GS v 0`) is
  /// the same standard graphics mode every printer in this class carries. It drives the
  /// outlet logo at the top of a receipt; a device that turns out not to support it
  /// simply prints a header with no logo.
  static const PrinterCapabilities escPos80mm = PrinterCapabilities(
    paperWidth: PaperWidth.mm80,
    hasAutoCutter: true,
    supportsQrCode: true,
    supportsGraphics: true,
  );

  /// A 58mm ESC/POS printer, otherwise identical.
  ///
  /// Declared because [PaperWidth.mm58] is, and because a configured roll width has to
  /// resolve to capabilities without a conditional at every call site. Nothing in this
  /// build targets it.
  static const PrinterCapabilities escPos58mm = PrinterCapabilities(
    paperWidth: PaperWidth.mm58,
    hasAutoCutter: true,
    supportsQrCode: true,
    supportsGraphics: true,
  );

  /// The ordinary ESC/POS printer that takes a [paper] roll.
  ///
  /// The cutter and the QR engine are assumed present, because every printer in this
  /// class has both. A device that turns out not to is corrected in the layout settings,
  /// where `PrintSettings.problems` already refuses a cut on a bladeless printer rather
  /// than sending a command it will ignore.
  static PrinterCapabilities escPosFor(PaperWidth paper) => switch (paper) {
    PaperWidth.mm58 => escPos58mm,
    PaperWidth.mm80 => escPos80mm,
  };

  final PaperWidth paperWidth;

  /// True when the printer can cut the roll itself.
  final bool hasAutoCutter;

  /// True when the printer renders a QR code from data, rather than needing one
  /// rasterised into a bitmap by the application.
  final bool supportsQrCode;

  /// True when arbitrary bitmaps can be printed, which a logo would need.
  final bool supportsGraphics;

  /// Always false for thermal paper. Declared so nothing has to assume it, and so
  /// a document never tries to convey meaning with colour.
  final bool isColour;

  /// Characters per line available to a layout.
  int get characterColumns => paperWidth.characterColumns;

  @override
  String toString() =>
      'PrinterCapabilities(${paperWidth.label}, '
      'cutter: $hasAutoCutter, qr: $supportsQrCode)';
}
