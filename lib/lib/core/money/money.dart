/// A monetary amount in Indian rupees, stored as an exact integer count of paise.
///
/// ## Representation
///
/// Every amount in this application is an `int` number of paise (1 rupee = 100
/// paise). `Money` is the only type allowed to carry a price, a total, a tax
/// figure or a discount. `double` is never used for money, and the SQLite schema
/// stores these values in `INTEGER` columns whose names end in `Paise`.
///
/// The reason is that binary floating point cannot represent most decimal
/// fractions. `0.1 + 0.2` is not `0.3`, and a bill that adds up two hundred line
/// items with `double` will drift by a paisa or more. A drifting total is a
/// legally incorrect GST invoice, so the representation is integral and every
/// operation below is exact.
///
/// ## Rounding
///
/// Only [applyRate] can produce a fraction of a paisa, because a tax or discount
/// percentage of an arbitrary amount usually does. It rounds half away from zero,
/// which is the convention Indian invoices use, and it is the single place in the
/// application where rounding happens.
class Money implements Comparable<Money> {
  /// Creates an amount from an exact count of paise.
  const Money.fromPaise(this.paise);

  /// Creates an amount from a whole number of rupees.
  const Money.fromRupees(int rupees) : paise = rupees * _paisePerRupee;

  /// Parses a decimal string such as `'249'`, `'249.5'` or `'249.50'`.
  ///
  /// Throws [FormatException] on anything else, including values with more than
  /// two decimal places, because silently discarding a third decimal would hide a
  /// data-entry mistake. Used for seed data and for parsing operator input, never
  /// in a calculation path.
  factory Money.parse(String value) {
    final String trimmed = value.trim();
    final RegExpMatch? match = _decimalPattern.firstMatch(trimmed);
    if (match == null) {
      throw FormatException('Not a valid money value', value);
    }

    final bool isNegative = match.group(1) == '-';
    final int rupees = int.parse(match.group(2)!);
    // Pad so '5' means 50 paise and '05' means 5 paise.
    final String fraction = (match.group(3) ?? '').padRight(2, '0');
    final int paisePart = fraction.isEmpty ? 0 : int.parse(fraction);

    final int total = rupees * _paisePerRupee + paisePart;
    return Money.fromPaise(isNegative ? -total : total);
  }

  static const int _paisePerRupee = 100;

  static final RegExp _decimalPattern = RegExp(r'^(-)?(\d+)(?:\.(\d{1,2}))?$');

  /// Zero rupees.
  static const Money zero = Money.fromPaise(0);

  /// The amount, as an exact count of paise. This is what is persisted.
  final int paise;

  bool get isZero => paise == 0;

  bool get isNegative => paise < 0;

  bool get isPositive => paise > 0;

  Money operator +(Money other) => Money.fromPaise(paise + other.paise);

  Money operator -(Money other) => Money.fromPaise(paise - other.paise);

  Money operator -() => Money.fromPaise(-paise);

  /// Multiplies by a whole count, for example a line quantity. Exact.
  Money operator *(int quantity) => Money.fromPaise(paise * quantity);

  /// Divides by a whole count, truncating towards zero at the paisa.
  ///
  /// For an average: the mean of a day's bills is not generally a whole number of
  /// paise, and the fraction has to go somewhere. It is dropped rather than rounded
  /// so the figure can never read higher than the takings actually support, and
  /// truncation is deterministic, which rounding a fraction of a paisa is not.
  ///
  /// This is the only division of an amount in the application, and it is integer
  /// division: no `double` is created at any point. Use [allocate] instead when the
  /// shares have to add back up to the original amount.
  ///
  /// Throws [ArgumentError] on a divisor of zero, because the mean of no bills is
  /// not zero rupees — it does not exist, and the caller has to say what to show.
  Money operator ~/(int divisor) {
    if (divisor == 0) {
      throw ArgumentError.value(divisor, 'divisor', 'Must not be zero');
    }
    return Money.fromPaise(paise ~/ divisor);
  }

  bool operator <(Money other) => paise < other.paise;

  bool operator <=(Money other) => paise <= other.paise;

  bool operator >(Money other) => paise > other.paise;

  bool operator >=(Money other) => paise >= other.paise;

  /// Applies a rate expressed in basis points, where 10000 basis points is 100%.
  ///
  /// Rates are integers for the same reason amounts are: 5% GST is `500`, not
  /// `0.05`. Rounds half away from zero.
  Money applyRate(int basisPoints) {
    final int numerator = paise * basisPoints;
    const int denominator = 10000;
    return Money.fromPaise(_divideRoundingHalfAway(numerator, denominator));
  }

  /// Splits the amount into [parts] shares that sum back to exactly this amount.
  ///
  /// The remainder paise are handed to the earliest shares, so nothing is created
  /// or destroyed. Intended for splitting a bill across payments.
  List<Money> allocate(int parts) {
    if (parts <= 0) {
      throw ArgumentError.value(parts, 'parts', 'Must be greater than zero');
    }

    final int base = paise ~/ parts;
    final int remainder = paise.remainder(parts).abs();
    final int sign = paise.isNegative ? -1 : 1;

    return List<Money>.generate(
      parts,
      (int index) => Money.fromPaise(base + (index < remainder ? sign : 0)),
      growable: false,
    );
  }

  static int _divideRoundingHalfAway(int numerator, int denominator) {
    final int quotient = numerator ~/ denominator;
    final int remainder = numerator.remainder(denominator);
    if (remainder == 0) {
      return quotient;
    }
    final bool roundsUp = remainder.abs() * 2 >= denominator.abs();
    if (!roundsUp) {
      return quotient;
    }
    return numerator.isNegative ? quotient - 1 : quotient + 1;
  }

  /// Sums a collection exactly.
  static Money sum(Iterable<Money> amounts) {
    int total = 0;
    for (final Money amount in amounts) {
      total += amount.paise;
    }
    return Money.fromPaise(total);
  }

  /// Renders the amount with two decimal places and no currency symbol, for
  /// example `1234.50`. Presentation code adds the symbol.
  String toDecimalString() {
    final int absolute = paise.abs();
    final String rupees = (absolute ~/ _paisePerRupee).toString();
    final String fraction = (absolute % _paisePerRupee).toString().padLeft(
      2,
      '0',
    );
    return '${paise.isNegative ? '-' : ''}$rupees.$fraction';
  }

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;

  @override
  String toString() => 'Money(${toDecimalString()})';
}
