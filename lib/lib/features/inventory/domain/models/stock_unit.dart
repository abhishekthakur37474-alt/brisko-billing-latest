/// How a stock item is measured.
///
/// A closed set rather than free text, because the unit is a fact about the item that
/// the operator has to be able to rely on. Free text lets `kg`, `Kg`, `kgs` and
/// `kilo` all exist for the same shelf, and a recipe written against one of them is
/// then quietly measured in another.
///
/// The set is deliberately small: weight, volume and count are the three things this
/// outlet buys in, and each is offered at the scale it is actually delivered and used
/// at. There is no conversion between members — an item tracked in kilograms is
/// counted in kilograms, and a recipe against it is written in thousandths of a
/// kilogram, which is a gram. Introducing conversion would mean deciding whether 1500
/// grams should be reported as `1.5 kg`, and that is a formatting preference the
/// client has not asked for.
///
/// Stored as the Dart name, like every other enum in this schema, so the database
/// stays readable and reordering this declaration cannot corrupt it.
enum StockUnit {
  gram(code: 'g', label: 'Gram'),
  kilogram(code: 'kg', label: 'Kilogram'),
  millilitre(code: 'ml', label: 'Millilitre'),
  litre(code: 'l', label: 'Litre'),
  piece(code: 'pc', label: 'Piece');

  const StockUnit({required this.code, required this.label});

  /// Short form shown beside a quantity, for example `kg`.
  final String code;

  /// Full name, for a form field where the short form would be cryptic.
  final String label;

  /// The unit used when a stored value cannot be recognised.
  ///
  /// A count is the least presumptuous fallback: it claims no scale and no
  /// substance, so an item that arrives with an unreadable unit is displayed as
  /// countable rather than being silently declared to be kilograms.
  static const StockUnit fallback = piece;

  /// Reads a stored or typed unit, by name or by short code, ignoring case.
  ///
  /// Both spellings are accepted because the column held free text before recipes
  /// existed. Returns `null` for anything else, so a caller validating operator
  /// input can refuse it rather than substitute something.
  static StockUnit? tryParse(String value) {
    final String normalised = value.trim().toLowerCase();
    if (normalised.isEmpty) {
      return null;
    }
    for (final StockUnit unit in values) {
      if (unit.name == normalised || unit.code == normalised) {
        return unit;
      }
    }
    return null;
  }

  /// [tryParse], falling back to [fallback] for an unreadable value.
  ///
  /// Used when reading a row. Failing the read instead would make the whole
  /// inventory list unopenable because of one bad row, which is a worse outcome than
  /// one item showing the wrong unit next to a balance the operator can correct.
  static StockUnit read(String value) => tryParse(value) ?? fallback;

  /// A quantity with its unit, for example `2.5 kg`.
  String describe(String quantity) => '$quantity $code';
}
