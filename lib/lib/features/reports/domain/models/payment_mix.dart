import '../../../../core/money/money.dart';
import '../../../payments/domain/models/payment_method.dart';

/// How a date range's takings were tendered, split by method.
///
/// ## Why every method is always present
///
/// [amountFor] and [countFor] answer for all four `PaymentMethod` values, returning zero
/// for a method nothing was taken on. A day with no card payments should read "Card
/// ₹0.00", not omit the row: a missing line looks like a report that forgot to include
/// card takings, and somebody reconciling a till needs to see the zero.
///
/// The four are exactly the values on `PaymentMethod`, which this type does not extend.
/// A wallet or a loyalty balance is not a tender this outlet accepts, and inventing a
/// bucket for one would put a heading on a report that no payment can ever land in.
///
/// ## What counts
///
/// Settled tenders against settled bills. A pending UPI attempt is not money in, and a
/// tender against a cancelled bill is not takings. The repository applies both filters;
/// see `SalesReportRepository`.
///
/// ## Money in and money back are separate buckets
///
/// [amountFor] is what came in on a method and never changes when a bill is refunded.
/// [refundedFor] is what went back out on that method, as a positive amount. [netFor] is
/// the difference. Keeping them apart is what lets a till be reconciled: the cash drawer
/// took [amountFor] and paid out [refundedFor], and both movements happened.
///
/// A refund is not a fifth tender. It goes back by the method it came in on, so it lands in
/// that method's refund bucket rather than a bucket of its own. `PaymentMethod` is
/// unchanged.
class PaymentMix {
  PaymentMix({
    required Map<PaymentMethod, Money> amounts,
    required Map<PaymentMethod, int> counts,
    Map<PaymentMethod, Money> refunds = const <PaymentMethod, Money>{},
    Map<PaymentMethod, int> refundCounts = const <PaymentMethod, int>{},
  }) : _amounts = Map<PaymentMethod, Money>.unmodifiable(amounts),
       _counts = Map<PaymentMethod, int>.unmodifiable(counts),
       _refunds = Map<PaymentMethod, Money>.unmodifiable(refunds),
       _refundCounts = Map<PaymentMethod, int>.unmodifiable(refundCounts);

  /// A range in which nothing was tendered.
  PaymentMix.empty()
    : _amounts = const <PaymentMethod, Money>{},
      _counts = const <PaymentMethod, int>{},
      _refunds = const <PaymentMethod, Money>{},
      _refundCounts = const <PaymentMethod, int>{};

  final Map<PaymentMethod, Money> _amounts;
  final Map<PaymentMethod, int> _counts;
  final Map<PaymentMethod, Money> _refunds;
  final Map<PaymentMethod, int> _refundCounts;

  /// The methods this report always reports on, in the order they are shown.
  ///
  /// Taken from the enum rather than listed, so a method added to `PaymentMethod` later
  /// appears here without anyone having to remember this file.
  static List<PaymentMethod> get methods => PaymentMethod.values;

  /// Total taken on [method]. [Money.zero] when nothing was.
  Money amountFor(PaymentMethod method) => _amounts[method] ?? Money.zero;

  /// Number of settled tenders on [method].
  int countFor(PaymentMethod method) => _counts[method] ?? 0;

  /// Total handed back on [method], as a positive amount. [Money.zero] when none was.
  Money refundedFor(PaymentMethod method) => _refunds[method] ?? Money.zero;

  /// Number of settled refunds on [method].
  int refundCountFor(PaymentMethod method) => _refundCounts[method] ?? 0;

  /// What [method] is left holding: taken in, less handed back.
  ///
  /// Exact integer subtraction. Can be negative when a range's refunds exceed its takings
  /// on a method, which is reported rather than clamped.
  Money netFor(PaymentMethod method) => amountFor(method) - refundedFor(method);

  /// Total taken across every method, before any refund. Exact.
  Money get total => Money.sum(methods.map(amountFor));

  /// Total handed back across every method, as a positive amount.
  Money get refundTotal => Money.sum(methods.map(refundedFor));

  /// What the till is left holding across every method: [total] less [refundTotal].
  ///
  /// This is the figure that reconciles against `SalesSummary.netSales`. The two are drawn
  /// from the same rows by the same query, so a mismatch between them is a real
  /// discrepancy in the records rather than an artefact of how they were counted.
  Money get netTotal => total - refundTotal;

  /// Number of settled tenders across every method.
  int get tenderCount =>
      methods.fold<int>(0, (int sum, PaymentMethod m) => sum + countFor(m));

  /// Number of settled refunds across every method.
  int get refundCount => methods.fold<int>(
    0,
    (int sum, PaymentMethod m) => sum + refundCountFor(m),
  );

  /// True when any money was handed back in the range.
  bool get hasRefunds => refundCount > 0;

  /// True when nothing was tendered in the range.
  ///
  /// Keyed on tenders rather than on the net figure: a range whose takings were entirely
  /// refunded still had money move through it twice, and calling that empty would hide both
  /// movements.
  bool get isEmpty => tenderCount == 0;

  @override
  String toString() => 'PaymentMix(${netTotal.toDecimalString()})';
}
