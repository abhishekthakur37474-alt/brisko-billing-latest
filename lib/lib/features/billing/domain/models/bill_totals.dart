import '../../../../core/money/money.dart';
import 'bill_discount.dart';
import 'cart.dart';
import 'gst_rate.dart';

/// The money on the face of a bill: what the lines came to, what was taken off, what tax
/// was added, and what is payable.
///
/// ## The one place the arithmetic happens
///
/// Every figure a customer sees comes from here, in this order:
///
/// ```
/// subtotal          sum of the line totals
///   - discount      the bill-level rule applied to the subtotal
///   = taxableAmount
///   + tax           taxableAmount at the GST rate
///   = total
/// ```
///
/// Discount before tax, because GST is charged on what the customer is actually paying
/// for the food. Taxing the full subtotal and then discounting would collect tax on money
/// nobody was charged.
///
/// The cart's own screen, the checkout review, the confirm step, the persisted order, the
/// printed receipt and the sales report all read this one result. None of them recomputes
/// it, which is what makes it impossible for the amount on the button to differ from the
/// amount in the till.
///
/// ## Rounding
///
/// Exactly one rounding, in `Money.applyRate`, half away from zero. The tax is computed
/// once on the taxable amount and then split for presentation, never computed twice — see
/// [cgst].
///
/// ## What a settled bill keeps
///
/// [taxRate] and [discountRule] are carried on this value and persisted with the order,
/// so a bill can state the rate it was charged at and the discount it was given. Changing
/// either setting afterwards cannot reach a bill that has already been written: the
/// figures are stored, and nothing recalculates a historical total.
class BillTotals {
  const BillTotals({
    required this.subtotal,
    this.discount = Money.zero,
    this.tax = Money.zero,
    this.taxRate = GstRate.zero,
    this.discountRule = BillDiscount.none,
  });

  /// Totals for a cart with no discount and no GST.
  ///
  /// The plain case, and the one a terminal that has configured no rate produces for every
  /// bill. Kept as its own factory because it is what a cart alone can answer: a discount
  /// is entered at settlement and a rate comes from settings, and neither is the cart's to
  /// know.
  factory BillTotals.fromCart(Cart cart) => BillTotals(subtotal: cart.subtotal);

  /// Totals for [cart] with [discount] taken off and [taxRate] applied.
  ///
  /// The authoritative calculation. Both arguments default to nothing, so this and
  /// [BillTotals.fromCart] agree exactly on a plain bill.
  ///
  /// The discount is resolved against the subtotal here rather than carried as a figure,
  /// so a rule and the amount it produced can never disagree. `BillDiscount.amountOn`
  /// clamps to the subtotal, which is what makes [taxableAmount] and [total] impossible to
  /// drive negative whatever is passed in.
  factory BillTotals.forCart({
    required Cart cart,
    BillDiscount discount = BillDiscount.none,
    GstRate taxRate = GstRate.zero,
  }) => BillTotals.of(
    subtotal: cart.subtotal,
    discount: discount,
    taxRate: taxRate,
  );

  /// Totals for a [subtotal] that has already been summed.
  ///
  /// The same arithmetic as [BillTotals.forCart], for a caller holding a subtotal rather
  /// than a cart. Both funnel through here so there is one implementation of the order of
  /// operations.
  factory BillTotals.of({
    required Money subtotal,
    BillDiscount discount = BillDiscount.none,
    GstRate taxRate = GstRate.zero,
  }) {
    final Money discountAmount = discount.amountOn(subtotal);
    final Money taxable = subtotal - discountAmount;

    return BillTotals(
      subtotal: subtotal,
      discount: discountAmount,
      // Charged on the taxable amount, not the subtotal. Rounded once, here.
      tax: taxable.applyRate(taxRate.basisPoints),
      taxRate: taxRate,
      discountRule: discount,
    );
  }

  /// Sum of the line totals, as the cart calculated them.
  final Money subtotal;

  /// What the bill-level discount took off. Never more than [subtotal].
  final Money discount;

  /// GST on [taxableAmount] at [taxRate]. [Money.zero] when no rate is configured.
  final Money tax;

  /// The rate [tax] was computed at.
  ///
  /// Carried so the bill can state it, and persisted so it stays true. A bill settled at
  /// 5% still says 5% after the outlet moves to 18%.
  final GstRate taxRate;

  /// The rule that produced [discount], for example `10%` or `₹100.00`.
  ///
  /// [BillDiscount.none] on a bill with no discount. The authoritative figure is
  /// [discount]; this explains it.
  final BillDiscount discountRule;

  /// What GST is charged on: [subtotal] less [discount].
  ///
  /// Never negative, because the discount is clamped to the subtotal before it gets here.
  Money get taxableAmount => subtotal - discount;

  /// Amount payable. Exact integer paise, in the order an invoice states it.
  Money get total => taxableAmount + tax;

  /// The central half of the GST, for the CGST line on the bill.
  ///
  /// [Money.allocate] splits [tax] into two shares that add back to exactly [tax], handing
  /// an odd paisa to the first. That matters: applying half the rate twice would round
  /// twice, and on a ₹900 taxable amount at 5% the two halves would come to ₹22.50 each
  /// against a tax of ₹45.00 — fine there, but a paisa short on plenty of other bills, and
  /// a bill whose halves do not add up to its own tax line is not a document anybody can
  /// defend.
  ///
  /// So the whole tax is authoritative and the halves are derived from it.
  Money get cgst => tax.allocate(2).first;

  /// The state half of the GST. [cgst] plus this is exactly [tax].
  Money get sgst => tax.allocate(2).last;

  /// True when there is something to collect. A bill of zero is not settleable.
  bool get isPayable => total.isPositive;

  /// True when a discount was taken off this bill.
  bool get hasDiscount => !discount.isZero;

  /// True when this bill carries a tax line.
  ///
  /// Keyed on the amount rather than on the rate, so a bill whose taxable amount rounded
  /// to nothing does not print a zero tax line either.
  bool get hasTax => !tax.isZero;

  /// True when [taxableAmount] is worth stating separately.
  ///
  /// Only when a discount moved it. With no discount it is the subtotal, and a second row
  /// repeating the figure above it tells the customer nothing.
  bool get showsTaxableAmount => hasDiscount && hasTax;

  /// True when anything was taken off or added, so the total is not just the subtotal.
  ///
  /// Lets a summary omit rows rather than print zeroes that imply a charge.
  bool get hasAdjustments => hasDiscount || hasTax;

  /// The same bill with [discount] applied instead.
  ///
  /// The rate is kept, and the tax is recomputed from the new taxable amount, because a
  /// discount changes what GST is due. Used as the operator types.
  BillTotals withDiscount(BillDiscount discount) =>
      BillTotals.of(subtotal: subtotal, discount: discount, taxRate: taxRate);

  /// True when this block adds up: subtotal less discount plus tax is exactly the total.
  ///
  /// This holds for every possible value, because [total] is derived from the other three
  /// rather than stored beside them — which is the point. A bill cannot be constructed whose
  /// parts disagree with its total, so there is no state for a caller to guard against.
  ///
  /// It is stated as a getter anyway, for two reasons. It documents the identity the rest of
  /// the application relies on, in the place that owns it. And it is the same question
  /// `CustomerReceiptTotals.isConsistent` asks of a bill read back off disk, where the total
  /// *is* a stored column and the answer genuinely can be no; keeping the two named alike
  /// makes it clear that the receipt is re-checking a persisted row rather than re-deriving
  /// it.
  ///
  /// What can go wrong here is a figure being negative or a discount exceeding the subtotal,
  /// which the const constructor will hold. `BillSettlement.isArithmeticSound` is what
  /// refuses those before a row is written.
  bool get isConsistent => subtotal - discount + tax == total;

  @override
  bool operator ==(Object other) {
    return other is BillTotals &&
        other.subtotal == subtotal &&
        other.discount == discount &&
        other.tax == tax &&
        other.taxRate == taxRate &&
        other.discountRule == discountRule;
  }

  @override
  int get hashCode =>
      Object.hash(subtotal, discount, tax, taxRate, discountRule);

  @override
  String toString() => 'BillTotals(total ${total.toDecimalString()})';
}
