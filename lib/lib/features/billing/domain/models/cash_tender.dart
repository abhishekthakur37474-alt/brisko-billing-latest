import '../../../../core/money/money.dart';

/// Cash handed over at the counter, and the change owed back.
///
/// ## Entry is digits, not text
///
/// The cashier types an amount on a keypad, and each press runs through
/// [appendDigit], which shifts the running amount one decimal place and adds the
/// digit: 3, 2, 0, 0 becomes 3, 32, 320, 3200 paise. That is integer arithmetic on
/// [Money].
///
/// It is deliberately not "read the text field and parse it". A parse would put a
/// `double` or a formatted string in the middle of the payment path, and a stray
/// character would either throw at the till or silently change the amount. Shifting
/// digits cannot produce a value that is not exactly what was pressed, and it is also
/// how a real cash drawer keypad behaves.
///
/// ## Change
///
/// [change] is only meaningful once [isSufficient] is true, and is zero before then
/// rather than negative, because a negative change figure on screen reads as money
/// owed to the customer.
class CashTender {
  const CashTender({required this.payable, this.tendered = Money.zero});

  /// Ceiling on the amount that can be keyed in, as an exact count of paise.
  ///
  /// A guard against a held key turning a ₹320 bill into a six-figure tender. Well
  /// above any note a customer can hand over.
  static const int maxTenderedPaise = 9999999;

  /// Notes offered as one-touch buttons. Current Indian denominations, largest last.
  static const List<Money> denominations = <Money>[
    Money.fromRupees(10),
    Money.fromRupees(20),
    Money.fromRupees(50),
    Money.fromRupees(100),
    Money.fromRupees(200),
    Money.fromRupees(500),
  ];

  /// Amount the bill comes to.
  final Money payable;

  /// Amount the customer has put down so far.
  final Money tendered;

  /// True when the cash covers the bill. Equal amounts count.
  bool get isSufficient => tendered >= payable;

  /// True when the exact amount was handed over, so no change is needed.
  bool get isExact => tendered == payable;

  /// True once anything at all has been keyed in.
  bool get hasTender => !tendered.isZero;

  /// Change owed to the customer, or zero while the tender is short.
  Money get change => isSufficient ? tendered - payable : Money.zero;

  /// How much more is needed, or zero once the tender covers the bill.
  Money get shortfall => isSufficient ? Money.zero : payable - tendered;

  /// Shifts the amount one place and adds [digit], for one keypad press.
  ///
  /// Ignores the press once [maxTenderedPaise] would be exceeded, so the amount on
  /// screen never disagrees with what was accepted. Throws [ArgumentError] for
  /// anything that is not a single digit, which would be a bug in the keypad.
  CashTender appendDigit(int digit) {
    if (digit < 0 || digit > 9) {
      throw ArgumentError.value(digit, 'digit', 'Must be a single digit 0-9');
    }

    final int next = tendered.paise * 10 + digit;
    if (next > maxTenderedPaise) {
      return this;
    }
    return CashTender(payable: payable, tendered: Money.fromPaise(next));
  }

  /// Undoes one keypad press.
  CashTender removeLastDigit() {
    return CashTender(
      payable: payable,
      tendered: Money.fromPaise(tendered.paise ~/ 10),
    );
  }

  /// Clears the amount keyed in, leaving the bill unchanged.
  CashTender cleared() => CashTender(payable: payable);

  /// Sets the tender to the exact amount payable, for the common case.
  CashTender exact() => CashTender(payable: payable, tendered: payable);

  /// Adds a note the customer handed over, for the denomination buttons.
  CashTender addNote(Money note) {
    final int next = tendered.paise + note.paise;
    if (next > maxTenderedPaise) {
      return this;
    }
    return CashTender(payable: payable, tendered: Money.fromPaise(next));
  }

  @override
  bool operator ==(Object other) {
    return other is CashTender &&
        other.payable == payable &&
        other.tendered == tendered;
  }

  @override
  int get hashCode => Object.hash(payable, tendered);

  @override
  String toString() =>
      'CashTender(payable ${payable.toDecimalString()}, '
      'tendered ${tendered.toDecimalString()})';
}
