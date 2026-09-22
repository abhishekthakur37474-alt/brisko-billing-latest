import '../../../../core/utils/result.dart';
import '../models/bill_search_query.dart';
import '../models/date_range.dart';
import '../models/item_sales_row.dart';
import '../models/payment_mix.dart';
import '../models/sales_bill.dart';
import '../models/sales_summary.dart';

/// Read-only access to what the outlet has sold.
///
/// ## Why reporting has its own repository
///
/// Every method here is an aggregate over a date range, and an aggregate is a query, not
/// a collection of entities. Asking `OrderRepository` for a range of orders and adding
/// them up in a controller would mean reading a month of bills into memory to produce six
/// numbers, and reading every line of every bill to produce an item report. The grouping
/// belongs in SQL, and SQL belongs in the data layer.
///
/// It is also read-only by design. Reports observe; nothing here writes a row, so no
/// report can alter a bill.
///
/// ## What counts as a sale
///
/// One rule, applied identically by every method: a bill counts when it is financially
/// settled, which is `OrderStatus.completed` — the status `CheckoutTransition` writes
/// when the money is taken. That excludes a cancelled bill, and a draft never reaches the
/// table at all, so neither can contribute to a figure. This is the same rule
/// `CustomerRepository` uses for a customer's spend, so the two can never disagree.
///
/// ## Gross, refunds and net
///
/// A refunded bill is still a settled bill and still counts, at the full amount it was rung
/// up for. Refunding does not move a bill's status or rewrite its total — see
/// `RefundPolicy` — so gross takings stay exactly what the day's receipts add up to, which
/// is what makes them auditable.
///
/// What a reversal adds is a second figure alongside the first. `SalesSummary.refundTotal`
/// is the money handed back on the bills in range and `SalesSummary.netSales` is the
/// difference; `PaymentMix` carries the same split per tender method. Both come from the
/// same statement as the gross they belong to, so `PaymentMix.netTotal` and
/// `SalesSummary.netSales` are counted over the same rows and a difference between them is a
/// real discrepancy rather than an artefact.
///
/// A refund never appears as a sale. It is a row in its own table, so no query here can
/// mistake it for a second bill: the bill count, the item report and the bills list are
/// untouched by one.
///
/// A reversal is attributed to the day of the *bill* it reverses, exactly as a tender is.
/// Money handed back next week against today's trade reduces today's net sales, which is
/// what keeps the payment mix reconciling with the sales summary for a given day.
///
/// ## Where the figures come from
///
/// The persisted snapshots: `orders` for the money, `order_items` for what was sold,
/// `payments` for how it was tendered, `refunds` for what went back. Never the menu.
/// Repricing, renaming or deleting a menu item changes what the next bill will say and
/// cannot change any of these numbers.
///
/// ## Ranges
///
/// A [DateRange] is a span of whole local days converted to a half-open UTC instant
/// range, so "today" means the outlet's today wherever the terminal is.
abstract interface class SalesReportRepository {
  /// Bill count, item count, the money and what was handed back, for [range].
  ///
  /// One grouped statement. Returns [SalesSummary.empty] for a range with no settled
  /// bills, which is a real answer rather than an absence.
  Future<Result<SalesSummary>> loadSummary(DateRange range);

  /// Settled takings and reversals in [range], split by tender method.
  ///
  /// One grouped statement. Covers all four `PaymentMethod` values; see [PaymentMix]. A
  /// refund is counted under the method the money went back by, which is the method it came
  /// in on. No tender type is added for refunds.
  Future<Result<PaymentMix>> loadPaymentMix(DateRange range);

  /// What was sold in [range], grouped by the stored item and size names, best-selling
  /// by value first.
  ///
  /// One grouped statement over `order_items`. [limit] caps the report at a length a
  /// person can read; the outlet's menu is far smaller than the default.
  Future<Result<List<ItemSalesRow>>> loadItemSales(
    DateRange range, {
    int limit,
  });

  /// The settled bills in [range], newest first.
  ///
  /// One statement, including how each was paid, its kitchen slip number, its customer and
  /// anything refunded against it. Deliberately not one query per bill: a busy Saturday is
  /// several hundred rows.
  ///
  /// A refunded bill appears here, at its full total, with `SalesBill.refundedAmount` saying
  /// what went back. It is not removed from the list, because it is a sale that happened.
  Future<Result<List<SalesBill>>> loadBills(DateRange range, {int limit});

  /// The settled bills matching [query], newest first.
  ///
  /// Order history: the cashier finding a bill by its number, the customer's phone, a date
  /// range or an order type, in any combination. Every criterion narrows the same set
  /// [loadBills] returns — settled bills only, so a cancelled or unsettled record never
  /// surfaces as a sale — and each carries the same figures, payment method, slip number,
  /// customer and refund state.
  ///
  /// A [query] with nothing set matches every settled bill, so the caller decides whether a
  /// blank search means "everything recent" or "nothing yet"; see `BillSearchQuery.isEmpty`.
  /// A phone search excludes walk-in bills, which have no number to match. Bill number and
  /// phone are matched anywhere within the stored value, so a partial number finds a bill.
  ///
  /// One statement, like [loadBills]: the filters become a `WHERE`, not a second pass in
  /// Dart, so a search of a year of trading is one indexed query rather than every bill read
  /// into memory.
  Future<Result<List<SalesBill>>> searchBills(
    BillSearchQuery query, {
    int limit,
  });
}
