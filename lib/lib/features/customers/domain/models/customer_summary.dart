import '../../../../core/money/money.dart';
import 'customer.dart';

/// A customer together with what their bills add up to.
///
/// ## Why this is not stored
///
/// [completedOrderCount], [totalSpent] and [lastOrderAt] are computed from the `orders`
/// table every time they are read. There are no matching columns on the customer row,
/// and there deliberately never will be: a stored total is a second source of truth
/// that disagrees with the bills the first time one is cancelled, refunded or corrected.
/// A summary is an answer, not a record.
///
/// ## Which orders count
///
/// Only settled bills — the orders checkout actually writes. A cancelled order stays
/// visible in the customer's history, because it happened, but it is not counted as an
/// order they placed and its total is not counted as money they spent.
///
/// ## What a refund does to these figures
///
/// A refunded bill is still a bill this customer placed, so it keeps counting in
/// [completedOrderCount] and its total keeps counting in [totalSpent]. The visit happened
/// and the sale happened; forgetting either would misrepresent the record, and a customer
/// whose visit count dropped when they were refunded would look like someone who had never
/// come in.
///
/// What the refund changes is [netSpent]: what they have actually paid this outlet, after
/// money handed back. That is the figure to judge a customer by, and it is derived from
/// [totalSpent] and [refundedTotal] rather than stored, so the three cannot disagree.
///
/// ## Money
///
/// [totalSpent] is a [Money] built from a sum of integer paise taken straight out of
/// SQLite. Nothing on this path parses a decimal string or touches a [double], so the
/// figure shown on the screen is the exact sum of the figures on the bills.
class CustomerSummary {
  const CustomerSummary({
    required this.customer,
    required this.completedOrderCount,
    required this.totalSpent,
    this.refundedTotal = Money.zero,
    this.lastOrderAt,
  });

  /// A customer with no bills yet.
  ///
  /// Reached when someone gave their number on an order that was never settled, or
  /// when a record was created before this outlet started taking phone numbers. Shown
  /// as zero rather than hidden, because the record genuinely exists.
  factory CustomerSummary.empty(Customer customer) => CustomerSummary(
    customer: customer,
    completedOrderCount: 0,
    totalSpent: Money.zero,
  );

  final Customer customer;

  /// Number of settled bills against this customer.
  final int completedOrderCount;

  /// Sum of the settled bills' persisted totals, before any reversal. Exact.
  final Money totalSpent;

  /// Sum of the settled refunds against those same bills, as a positive amount.
  ///
  /// Positive because it is a quantity of money that moved back, not a negative sale.
  /// [netSpent] is where the direction is applied. Zero by default, so a summary built
  /// before refunds existed reads as a customer with none.
  final Money refundedTotal;

  /// When the most recent settled bill was taken, or `null` if there is none.
  ///
  /// Stored in UTC like every other timestamp. Presentation converts it.
  ///
  /// Unaffected by a refund: the visit happened when it happened.
  final DateTime? lastOrderAt;

  String get id => customer.id;

  String get phone => customer.phone;

  bool get hasOrders => completedOrderCount > 0;

  /// What this customer has actually paid: [totalSpent] less [refundedTotal].
  ///
  /// Derived, never stored. Exact integer subtraction.
  Money get netSpent => totalSpent - refundedTotal;

  /// True when any money has been handed back to this customer.
  bool get hasRefunds => !refundedTotal.isZero;

  /// Average spend per settled bill, or zero when there are none.
  ///
  /// Integer division on paise, so it cannot drift. Present because it is the one
  /// figure a counter reads off a customer record without doing arithmetic in their
  /// head; nothing else is derived here.
  ///
  /// Computed from [netSpent], not [totalSpent]: an average of what a customer was billed
  /// rather than what they kept would overstate someone whose orders were handed back.
  Money get averageOrderValue => completedOrderCount == 0
      ? Money.zero
      : Money.fromPaise(netSpent.paise ~/ completedOrderCount);

  @override
  String toString() =>
      'CustomerSummary(${customer.phone}, $completedOrderCount orders, '
      '${netSpent.toDecimalString()})';
}
