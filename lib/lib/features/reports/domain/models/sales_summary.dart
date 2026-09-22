import '../../../../core/money/money.dart';

/// What a date range sold, aggregated from the persisted bills.
///
/// ## What counts
///
/// Settled bills only. A draft never reaches the `orders` table at all, and a
/// cancelled bill is excluded by the repository's status filter, so neither can
/// contribute a paisa here. See `SalesReportRepository`.
///
/// ## What the figures are
///
/// Every amount is a sum of the `Paise` columns written when each bill was settled.
/// Nothing is recalculated from the menu and nothing is recomputed from the lines: the
/// figures are the amounts the customers were actually charged. [grossSales] is the
/// total payable — after discount, including tax — which is the number that has to
/// agree with the till.
///
/// [subtotal], [discountTotal] and [taxTotal] are carried alongside so the gross can be
/// read as a sum rather than taken on trust.
///
/// ## Gross and net are both here, and both are needed
///
/// [grossSales] is what was rung up. [refundTotal] is what was handed back on those same
/// bills. [netSales] is the difference, and it is derived rather than stored so the three
/// cannot disagree.
///
/// A refund does not remove a bill from [billCount] or from [grossSales], and that is
/// deliberate. The sale happened, the customer was given a receipt for it, and gross
/// takings is the figure reconciled against the day's receipts. Netting a reversal into the
/// gross would make a bill that exists unaccountable. See `RefundPolicy`.
class SalesSummary {
  const SalesSummary({
    required this.billCount,
    required this.itemCount,
    required this.subtotal,
    required this.discountTotal,
    required this.taxTotal,
    required this.grossSales,
    this.refundTotal = Money.zero,
  });

  /// A range with no settled bills in it.
  ///
  /// Zero bills and zero rupees, which is the honest answer for a quiet morning and is
  /// deliberately the same shape as a busy one. The screen decides how to say "nothing
  /// yet"; there is no sentinel value here to misread.
  static const SalesSummary empty = SalesSummary(
    billCount: 0,
    itemCount: 0,
    subtotal: Money.zero,
    discountTotal: Money.zero,
    taxTotal: Money.zero,
    grossSales: Money.zero,
  );

  /// Number of settled bills.
  final int billCount;

  /// Units sold across those bills, summed from the stored line quantities.
  final int itemCount;

  /// Sum of the bills' subtotals, before bill-level discount and tax.
  final Money subtotal;

  final Money discountTotal;

  /// Sum of the GST charged across those bills, as each bill recorded it.
  ///
  /// Each contributing figure was computed at the rate in force when that bill was settled,
  /// so a range spanning a rate change totals what was actually charged rather than
  /// restating the earlier bills at the later rate. Nothing here reads the current setting.
  final Money taxTotal;

  /// Sum of the bills' totals as rung up, before any reversal.
  final Money grossSales;

  /// Sum of the settled refunds against those same bills, as a positive amount.
  ///
  /// Positive because it is a quantity of money that moved, not a negative sale. [netSales]
  /// is where the direction is applied. Zero by default, so a report built before refunds
  /// existed reads as a report with none.
  final Money refundTotal;

  /// What GST was charged on across the range: [subtotal] less [discountTotal].
  ///
  /// Derived from two sums rather than summed itself, so it cannot disagree with them. It is
  /// the figure that reconciles the tax: taxable sales plus [taxTotal] is [grossSales].
  Money get taxableSales => subtotal - discountTotal;

  /// The central half of the GST charged, for a CGST line on the report.
  ///
  /// Split from [taxTotal] by `Money.allocate`, so the two halves add back to exactly the
  /// tax that was charged. Deliberately not a sum of each bill's own CGST: that would be a
  /// second aggregation of the same money, and the two could differ by a paisa per bill.
  ///
  /// This is a presentation of one total, and it is the only tax breakdown the report
  /// carries. One useful GST figure is what a single outlet files from.
  Money get cgstTotal => taxTotal.allocate(2).first;

  /// The state half of the GST charged. [cgstTotal] plus this is exactly [taxTotal].
  Money get sgstTotal => taxTotal.allocate(2).last;

  /// True when any GST was charged in the range.
  bool get hasTax => !taxTotal.isZero;

  /// True when any discount was given in the range.
  bool get hasDiscounts => !discountTotal.isZero;

  /// What the range actually earned: [grossSales] less [refundTotal].
  ///
  /// Derived, never stored. Integer subtraction of two exact paise figures, so it is exact.
  /// It can legitimately be negative — a quiet morning in which yesterday's large bill was
  /// refunded really did take less than nothing — and that is reported rather than clamped,
  /// because a floor at zero would hide money that left the till.
  Money get netSales => grossSales - refundTotal;

  /// True when any money was handed back in the range.
  bool get hasRefunds => !refundTotal.isZero;

  /// True when nothing was sold in the range.
  ///
  /// Still keyed on [billCount] rather than on an amount: a range in which one bill was
  /// rung up and fully refunded is not an empty range, and showing the empty state for it
  /// would hide both facts.
  bool get isEmpty => billCount == 0;

  /// Mean value of a settled bill, truncated to the paisa.
  ///
  /// [Money.zero] when there were no bills. Zero is not the mean of nothing, but a
  /// range with no sales has no average to show and the screen renders the empty state
  /// instead of this figure; returning zero keeps the getter total rather than making
  /// every caller handle a null it will not display.
  ///
  /// Integer division throughout. A mean computed in floating point and then rounded
  /// would differ from this in the last paisa often enough to be noticed, and there is
  /// no reason to introduce a `double` to get a worse answer.
  Money get averageBillValue =>
      billCount == 0 ? Money.zero : grossSales ~/ billCount;

  @override
  String toString() =>
      'SalesSummary($billCount bills, ${grossSales.toDecimalString()})';
}
