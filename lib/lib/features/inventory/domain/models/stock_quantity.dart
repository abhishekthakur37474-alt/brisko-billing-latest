/// Conversions for the integer representation every stock quantity uses.
///
/// ## Representation
///
/// A quantity is an exact `int` count of thousandths of the item's unit. `2.5 kg` is
/// `2500`, `150 g` of a kilogram-tracked item is `150`, and one piece is `1000`.
/// Columns holding these values are `INTEGER` and are suffixed `Milli`.
///
/// The reason is the same one that makes money integer paise. A balance is a running
/// total: stock arrives in kilograms, leaves in grams, and the arithmetic is applied
/// hundreds of times a week. Binary floating point cannot represent most decimal
/// fractions, so a `double` balance drifts, and a drifting balance is a figure that no
/// longer matches the shelf. Three decimal places is the precision the outlet actually
/// works to — grams within a kilogram, millilitres within a litre — so thousandths are
/// exact rather than approximately right.
///
/// ## Why parsing takes a string
///
/// [parse] is the only way a typed quantity enters the system, and it goes straight
/// from text to `int`. There is deliberately no path through `double`, because
/// `(2.5 * 1000).round()` is a conversion that works until the day it does not.
class StockQuantity {
  const StockQuantity._();

  /// Thousandths in one whole unit.
  static const int perUnit = 1000;

  /// Zero, for readability at call sites.
  static const int zero = 0;

  /// Up to three decimal places, optionally signed.
  static final RegExp _pattern = RegExp(r'^(-)?(\d+)(?:\.(\d{1,3}))?$');

  /// Converts a display quantity such as `2.5` into thousandths.
  ///
  /// Throws [FormatException] on anything else, including a value with more than
  /// three decimal places. Silently dropping a fourth decimal would hide a
  /// data-entry mistake in a figure the operator is counting against a shelf.
  static int parse(String value) {
    final RegExpMatch? match = _pattern.firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Not a valid quantity', value);
    }
    final int whole = int.parse(match.group(2)!);
    // Padded so '5' means 500 thousandths and '005' means 5.
    final String fraction = (match.group(3) ?? '').padRight(3, '0');
    final int total =
        whole * perUnit + (fraction.isEmpty ? 0 : int.parse(fraction));
    return match.group(1) == '-' ? -total : total;
  }

  /// [parse], or `null` when [value] is not a quantity. For form validation.
  static int? tryParse(String value) {
    try {
      return parse(value);
    } on FormatException {
      return null;
    }
  }

  /// Renders thousandths as a trimmed decimal string, for example `2.5`.
  ///
  /// Trailing zeroes are dropped, so a whole quantity reads as `10` rather than
  /// `10.000`. This is display only; nothing parses the result back.
  static String format(int milli) {
    final int absolute = milli.abs();
    final String whole = (absolute ~/ perUnit).toString();
    final String fraction = (absolute % perUnit)
        .toString()
        .padLeft(3, '0')
        .replaceAll(RegExp(r'0+$'), '');
    final String sign = milli.isNegative ? '-' : '';
    return fraction.isEmpty ? '$sign$whole' : '$sign$whole.$fraction';
  }

  /// The amount one sold unit consumes, times how many were sold. Exact.
  ///
  /// The whole of scaling a recipe to a bill line is this one multiplication. It is
  /// named so that the deduction reads as what it is, and so that there is a single
  /// place to look for the arithmetic behind a stock figure.
  static int forQuantity(int perUnitMilli, int soldQuantity) =>
      perUnitMilli * soldQuantity;
}
