import '../../../../core/money/money.dart';

/// How a bill-level discount is expressed.
enum BillDiscountType {
  /// A proportion of the subtotal, held in basis points.
  percentage,

  /// A flat sum off the subtotal, held in paise.
  amount;

  String get label => switch (this) {
    BillDiscountType.percentage => 'Percentage',
    BillDiscountType.amount => 'Amount',
  };

  /// The unit the operator types a value in, for a field suffix.
  String get unit => switch (this) {
    BillDiscountType.percentage => '%',
    BillDiscountType.amount => '\u20B9',
  };

  /// The type named by [stored], or `null` when it names none.
  ///
  /// Stored by enum name, so reordering this declaration cannot change what a settled
  /// bill says its discount was.
  static BillDiscountType? tryParse(String? stored) {
    if (stored == null) {
      return null;
    }
    for (final BillDiscountType type in BillDiscountType.values) {
      if (type.name == stored) {
        return type;
      }
    }
    return null;
  }
}

/// A discount taken off the whole bill, as the rule that produced it.
///
/// ## Why the rule is carried rather than just the amount
///
/// `₹100 off` and `10% off a ₹1,000 bill` reduce to the same ₹100, and on the day it does
/// not matter which was applied. It matters afterwards: the operator checking a bill
/// wants to see that they gave ten percent, and a discount whose rule is lost cannot be
/// explained to the customer who is querying it. So the rule is persisted alongside the
/// amount it produced, and the amount is still what the bill was settled for — nothing
/// recomputes a historical discount from its rule.
///
/// ## Every value is an integer
///
/// A percentage is basis points, where 10000 is 100%, so 10% is `1000` and 12.5% is
/// `1250`. A flat discount is a [Money] in exact paise. There is no `double` anywhere on
/// this class, and [amountOn] performs no construction at all: it either applies a rate
/// through `Money.applyRate`, which rounds once and half away from zero, or it returns
/// the flat amount clamped to the subtotal.
///
/// ## Why it cannot produce a negative bill
///
/// Two separate guards, because they answer different questions.
///
/// [problemOn] refuses a discount before it is applied and says why, which is what the
/// operator needs: a discount larger than the bill is a mistyped figure, not an
/// instruction to hand money over.
///
/// [amountOn] then clamps regardless. That is not redundancy — it is the guarantee that
/// holds if a caller ever forgets to ask. `subtotal - amountOn(subtotal)` is never
/// negative for any value this class can hold, so no route through the calculation can
/// produce a bill that pays the customer.
class BillDiscount {
  /// A discount of [basisPoints] off the subtotal, where 10000 is 100%.
  const BillDiscount.percentage(this.basisPoints)
    : type = BillDiscountType.percentage,
      fixedAmount = Money.zero;

  /// A flat sum off the subtotal.
  const BillDiscount.amount(this.fixedAmount)
    : type = BillDiscountType.amount,
      basisPoints = 0;

  /// No discount. What every bill starts on.
  ///
  /// Expressed as zero percent rather than as a fourth state, so there is one code path:
  /// a bill with no discount runs the same arithmetic as a bill with one and arrives at
  /// zero. [isNone] is what the screen and the receipt ask.
  static const BillDiscount none = BillDiscount.percentage(0);

  /// Basis points in 100%, and therefore the largest percentage discount.
  static const int maxBasisPoints = 10000;

  /// Basis points in one percent.
  static const int basisPointsPerPercent = 100;

  /// Ceiling on a flat discount, as an exact count of paise.
  ///
  /// The same ceiling `CashTender` puts on a keyed amount, and for the same reason: a
  /// held key must not turn a ₹40 discount into a six-figure one. A discount larger than
  /// the bill is refused by [problemOn] in any case; this stops the *entry* from becoming
  /// a number nobody typed.
  static const int maxFixedPaise = 9999999;

  /// Which of the two rules this is.
  final BillDiscountType type;

  /// The rate, in basis points, when [type] is a percentage. Zero otherwise.
  final int basisPoints;

  /// The flat sum, when [type] is an amount. [Money.zero] otherwise.
  final Money fixedAmount;

  /// True when this discount takes nothing off, whichever rule it is.
  bool get isNone => switch (type) {
    BillDiscountType.percentage => basisPoints == 0,
    BillDiscountType.amount => fixedAmount.isZero,
  };

  /// True when this rule is one a bill may be settled with.
  ///
  /// A percentage has to sit between 0% and 100%: a negative one would add to the bill
  /// and one above 100% would take off more than the bill came to. A flat discount has to
  /// be zero or more and within [maxFixedPaise]. Whether it also fits a *particular*
  /// subtotal is [problemOn], because that depends on the bill.
  bool get isWellFormed => switch (type) {
    BillDiscountType.percentage =>
      basisPoints >= 0 && basisPoints <= maxBasisPoints,
    BillDiscountType.amount =>
      !fixedAmount.isNegative && fixedAmount.paise <= maxFixedPaise,
  };

  /// The stored form of the value, as an integer.
  ///
  /// Basis points for a percentage and paise for an amount — hundredths either way, which
  /// is why one `INTEGER` column carries both. It is read back only in the company of
  /// [type], which says which unit it is in.
  int get storedValue => switch (type) {
    BillDiscountType.percentage => basisPoints,
    BillDiscountType.amount => fixedAmount.paise,
  };

  /// What this rule takes off [subtotal]. Never more than [subtotal], never negative.
  ///
  /// Exact integer arithmetic. A percentage goes through `Money.applyRate`, which is the
  /// single place in the application a fraction of a paisa is rounded, and it rounds half
  /// away from zero the way an Indian invoice does. A flat discount is returned as it
  /// stands unless it exceeds the bill, in which case the whole bill is taken off and the
  /// total lands on zero rather than below it.
  ///
  /// No amount is constructed here. The figure returned is either the subtotal scaled by
  /// a rate or one of the two amounts already held, which is what makes this safe to call
  /// from anywhere on the payment path.
  Money amountOn(Money subtotal) {
    if (subtotal.isNegative || subtotal.isZero) {
      return Money.zero;
    }

    final Money raw = switch (type) {
      BillDiscountType.percentage => subtotal.applyRate(
        _clampBasisPoints(basisPoints),
      ),
      BillDiscountType.amount => fixedAmount,
    };

    if (raw.isNegative) {
      return Money.zero;
    }
    return raw > subtotal ? subtotal : raw;
  }

  /// Why this discount is refused on a bill of [subtotal], or `null` when it is allowed.
  ///
  /// Operator-facing wording, kept beside the rule it explains so the two cannot drift.
  /// Each message says what is wanted instead, because "invalid" at a counter with a queue
  /// is not an instruction.
  String? problemOn(Money subtotal) {
    switch (type) {
      case BillDiscountType.percentage:
        if (basisPoints < 0) {
          return 'A discount cannot be a negative percentage.';
        }
        if (basisPoints > maxBasisPoints) {
          return 'A discount cannot be more than 100%.';
        }
      case BillDiscountType.amount:
        if (fixedAmount.isNegative) {
          return 'A discount cannot be a negative amount.';
        }
        if (fixedAmount.paise > maxFixedPaise) {
          return 'That discount is larger than this till accepts.';
        }
        if (fixedAmount > subtotal) {
          return 'A discount cannot be more than the '
              '${subtotal.toDecimalString()} subtotal.';
        }
    }
    return null;
  }

  /// `10%` or `₹100.00`, for the screen and the printed bill.
  ///
  /// Built by integer division and remainder, so a percentage label is exact and a
  /// trailing zero is dropped: `5%`, not `5.00%`.
  String get label {
    switch (type) {
      case BillDiscountType.percentage:
        final int percent = basisPoints ~/ basisPointsPerPercent;
        final int fraction = basisPoints.remainder(basisPointsPerPercent).abs();
        if (fraction == 0) {
          return '$percent%';
        }
        final String padded = fraction.toString().padLeft(2, '0');
        return '$percent.${padded.endsWith('0') ? padded.substring(0, 1) : padded}%';
      case BillDiscountType.amount:
        return '${BillDiscountType.amount.unit}${fixedAmount.toDecimalString()}';
    }
  }

  /// The rule the operator typed, or `null` when what they typed is not one.
  ///
  /// ## Why parsing lives here
  ///
  /// This is the only place in the billing feature that turns characters into a number,
  /// and it is deliberately one small named file — the same arrangement `CashTender` has
  /// for keyed cash and `StockQuantity` has for a typed quantity. Parsing in a controller
  /// would put `int.parse` on the payment path at a site nobody was watching.
  ///
  /// ## Why there is no double
  ///
  /// `12.5` is split on the decimal point and both halves are parsed as integers, then
  /// combined as `whole * 100 + hundredths`. That is exact. Going through
  /// `double.parse('12.5')` and multiplying by 100 would give 1250.0000000000002 on some
  /// inputs, and the rate that came out would be a rate nobody entered.
  ///
  /// Blank reads as [none], because clearing the field is how a discount is removed. An
  /// empty bill is a normal state, not an error.
  ///
  /// Anything else is `null`: more than two decimal places, a sign, a space in the middle,
  /// a letter, `1e3`, `Infinity`, `NaN`. None of those is a discount, and none is
  /// silently reinterpreted as one — a value that cannot be read is reported rather than
  /// rounded into something plausible.
  static BillDiscount? tryParse({
    required BillDiscountType type,
    required String value,
  }) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return none;
    }

    final int? hundredths = _hundredthsOf(trimmed);
    if (hundredths == null) {
      return null;
    }

    final BillDiscount parsed = switch (type) {
      BillDiscountType.percentage => BillDiscount.percentage(hundredths),
      BillDiscountType.amount => BillDiscount.amount(
        Money.fromPaise(hundredths),
      ),
    };

    return parsed.isWellFormed ? parsed : null;
  }

  /// The rule recorded against a settled bill, or `null` when none was.
  ///
  /// [storedType] is a [BillDiscountType] name and [storedValue] its magnitude in
  /// hundredths — basis points for a percentage, paise for a flat amount. Both come from
  /// the order row; see `M009BillTaxAndDiscount`.
  ///
  /// `null` for a bill with no rule recorded, which includes every bill settled before the
  /// columns existed. That is not the same as a rule worth nothing, and the caller shows the
  /// difference: a bill with no recorded rule prints its discount amount without an
  /// explanation rather than with an invented one.
  ///
  /// A rule that reads but is malformed — a stored percentage above 100%, from a corrupt row
  /// — also returns `null`. The bill's *amounts* are stored figures and print correctly
  /// either way; what is dropped is only a label that would have been wrong.
  ///
  /// Nothing here recalculates a historical discount. The amount on the bill is the amount
  /// in `discountAmountPaise`; this only says how it was arrived at.
  static BillDiscount? fromStored({
    required String? storedType,
    required int storedValue,
  }) {
    final BillDiscountType? type = BillDiscountType.tryParse(storedType);
    if (type == null) {
      return null;
    }

    final BillDiscount rule = switch (type) {
      BillDiscountType.percentage => BillDiscount.percentage(storedValue),
      BillDiscountType.amount => BillDiscount.amount(
        Money.fromPaise(storedValue),
      ),
    };

    return rule.isWellFormed ? rule : null;
  }

  /// `'12.5'` as `1250`, or `null` when [value] is not a plain decimal.
  ///
  /// Anchored, so nothing before or after the number is tolerated, and capped at two
  /// decimal places, because a third would have to be dropped and dropping it would hide
  /// a typing mistake. Unsigned: a minus sign is not a discount that gives money back,
  /// it is a mistake, and refusing it here is clearer than accepting it and refusing it
  /// again in [problemOn].
  static int? _hundredthsOf(String value) {
    final RegExpMatch? match = _decimalPattern.firstMatch(value);
    if (match == null) {
      return null;
    }

    final int whole = int.parse(match.group(1)!);
    // Padded so '5' means 50 hundredths and '05' means 5, matching how Money reads a
    // decimal string.
    final String fraction = (match.group(2) ?? '').padRight(2, '0');
    final int hundredths = fraction.isEmpty ? 0 : int.parse(fraction);

    return whole * 100 + hundredths;
  }

  static final RegExp _decimalPattern = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$');

  /// [points] held inside 0–100%, so a rate can never scale a subtotal upwards.
  ///
  /// [isWellFormed] and [problemOn] already refuse anything outside the range, so this
  /// only runs for a value that got past both. It is here because [amountOn] promises a
  /// figure no larger than the subtotal to every caller, and that promise should not
  /// depend on the caller having validated first.
  static int _clampBasisPoints(int points) => points.clamp(0, maxBasisPoints);

  @override
  bool operator ==(Object other) =>
      other is BillDiscount &&
      other.type == type &&
      other.basisPoints == basisPoints &&
      other.fixedAmount == fixedAmount;

  @override
  int get hashCode => Object.hash(type, basisPoints, fixedAmount);

  @override
  String toString() => 'BillDiscount($label)';
}
