/// Physical roll width, and the layout budget that follows from it.
///
/// ## Why this is a type and not a number
///
/// Every line of a thermal document is laid out in fixed-width characters, so the
/// column count is the single most important fact about the paper. Passing an `int`
/// around would let a 58mm width reach an 80mm layout with no complaint and produce
/// documents that wrap in the wrong places on real paper. A type makes the width a
/// decision taken once, in one place.
///
/// ## The numbers
///
/// [mm80] is the roll the outlet has chosen. An 80mm ESC/POS printer has a 72mm
/// printable area, which is 576 dots at the 203dpi that these printers use. Font A is
/// 12 dots wide, giving 48 characters per line, and Font B is 9 dots, giving 64. Every
/// layout here is built for Font A at 48 columns.
///
/// [mm58] is declared because the constants are known and a 58mm roll is what a
/// handheld printer uses, but nothing in this build targets it. It exists so that
/// supporting one later is a value, not a rewrite.
enum PaperWidth {
  mm58(millimetres: 58, printableDots: 384, characterColumns: 32),
  mm80(millimetres: 80, printableDots: 576, characterColumns: 48);

  const PaperWidth({
    required this.millimetres,
    required this.printableDots,
    required this.characterColumns,
  });

  /// Nominal roll width in millimetres, as printed on the box.
  final int millimetres;

  /// Printable area in dots at 203dpi. Needed for a QR code or a logo bitmap,
  /// which are sized in dots rather than characters.
  final int printableDots;

  /// Characters per line in Font A. This is the layout budget.
  final int characterColumns;

  String get label => '${millimetres}mm';
}
