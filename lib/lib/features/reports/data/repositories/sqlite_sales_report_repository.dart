import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_status.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../payments/domain/models/payment_status.dart';
import '../../../payments/domain/models/refund_policy.dart';
import '../../domain/models/bill_search_query.dart';
import '../../domain/models/date_range.dart';
import '../../domain/models/item_sales_row.dart';
import '../../domain/models/payment_mix.dart';
import '../../domain/models/sales_bill.dart';
import '../../domain/models/sales_summary.dart';
import '../../domain/repositories/sales_report_repository.dart';

/// SQLite implementation of [SalesReportRepository].
///
/// ## One statement per report
///
/// Each of the four methods issues exactly one query, whatever the size of the range. A
/// month of trading is the same number of round trips as an empty afternoon. The
/// aggregation is done by SQLite over the `INTEGER` paise columns, so the sums come back
/// as integers and no amount is ever assembled from text or a decimal.
///
/// The bills list is where this takes effort: it needs each bill's payment method, its
/// kitchen slip number and its customer, which live in three other tables. Reading them
/// per row would be four queries a bill. Instead the customer comes through a `LEFT JOIN`
/// and the other two through scalar subqueries inside the same statement.
///
/// ## Common table expressions
///
/// Three of the four queries name the settled bills in a `WITH` clause before using them.
/// That is not decoration: it puts the range and status filter in one place per statement,
/// so the summary cannot count a set of bills that the item report excludes, and it keeps
/// every bound parameter in the order it is written.
///
/// ## What is never read
///
/// No menu table. Not once. Every name, size, quantity and amount below comes from the
/// snapshot columns written when the bill was settled, which is what makes a report of
/// last month still true after this month's price rise.
class SqliteSalesReportRepository implements SalesReportRepository {
  /// The parameter is named `database` at the call site: an initializing formal for a
  /// private field drops the underscore from its public name.
  const SqliteSalesReportRepository({required this._database});

  /// The status a bill has once the money is in.
  ///
  /// `OrderStatus.completed`, which is what `CheckoutTransition.settledOrderStatus`
  /// writes. A cancelled bill is therefore excluded, and a draft has no row to exclude.
  /// Named once here so the four queries cannot drift apart.
  static final String _settledOrder = OrderStatus.completed.name;

  /// The status a tender has once the money has actually arrived.
  static final String _settledPayment = PaymentStatus.completed.name;

  /// The status a refund has once the money has actually gone back out.
  ///
  /// The same token as [_settledPayment], from the same enum, because "money that has
  /// moved" is one idea. Named separately so the two filters read as what they each mean at
  /// their call site. See `RefundPolicy.completedRefundStatus`.
  static final String _settledRefund = RefundPolicy.completedRefundStatus.name;

  final SqliteDatabase _database;

  Database get _db => _database.database;

  /// Bill count, units sold, the money and what was handed back, in one statement.
  ///
  /// The bills in range are named once in the `WITH` clause and then summed six ways, so
  /// the item count and the refunds are over exactly the bills the money is over.
  ///
  /// The refund subquery is the only addition a reversal makes to this report. Nothing here
  /// subtracts it: `grossPaise` stays the sum of the bills as rung up, and `SalesSummary`
  /// derives the net. A report that netted in SQL would have no way left to state the gross,
  /// which is the figure reconciled against the day's receipts.
  @override
  Future<Result<SalesSummary>> loadSummary(DateRange range) {
    return SqliteErrorMapper.guard<SalesSummary>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        ${_settledBillsCte()}
        SELECT
          (SELECT COUNT(*) FROM settled) AS billCount,
          (SELECT COALESCE(SUM(subtotalPaise), 0) FROM settled) AS subtotalPaise,
          (SELECT COALESCE(SUM(discountAmountPaise), 0) FROM settled)
            AS discountPaise,
          (SELECT COALESCE(SUM(taxAmountPaise), 0) FROM settled) AS taxPaise,
          (SELECT COALESCE(SUM(totalAmountPaise), 0) FROM settled) AS grossPaise,
          -- Units sold, over the lines of those same bills. A soft-deleted line is
          -- excluded, matching every other read of this table.
          (
            SELECT COALESCE(SUM(i.quantity), 0)
            FROM ${SqliteTables.orderItems} i
            WHERE i.${SyncColumns.isDeleted} = 0
              AND i.orderId IN (SELECT ${SyncColumns.id} FROM settled)
          ) AS itemCount,
          -- Money handed back on those same bills. Stored positive; the direction is the
          -- table it comes from, not a sign, so this cannot be netted by accident.
          (
            SELECT COALESCE(SUM(r.amountPaise), 0)
            FROM ${SqliteTables.refunds} r
            WHERE r.${SyncColumns.isDeleted} = 0
              AND r.status = ?
              AND r.orderId IN (SELECT ${SyncColumns.id} FROM settled)
          ) AS refundPaise
        ''',
        <Object?>[..._rangeArgs(range), _settledRefund],
      );

      final Map<String, Object?> row = rows.first;

      return SalesSummary(
        billCount: row.optionalInt('billCount'),
        itemCount: row.optionalInt('itemCount'),
        // Every one of these came out of an INTEGER column as an integer.
        subtotal: Money.fromPaise(row.optionalInt('subtotalPaise')),
        discountTotal: Money.fromPaise(row.optionalInt('discountPaise')),
        taxTotal: Money.fromPaise(row.optionalInt('taxPaise')),
        grossSales: Money.fromPaise(row.optionalInt('grossPaise')),
        refundTotal: Money.fromPaise(row.optionalInt('refundPaise')),
      );
    }, context: 'total the sales');
  }

  /// Takings and reversals by tender method, in one grouped statement.
  ///
  /// Filtered on the *bill's* date, not the payment's. A tender recorded a moment after
  /// midnight against a bill taken before it belongs to the day of the bill, or the
  /// payment report would not add up to the sales report. A refund is attributed the same
  /// way, and for the same reason: the reversal belongs to the day of the trade it reverses,
  /// which is what makes the payment mix reconcile with the sales summary for that day
  /// however long afterwards the money went back.
  ///
  /// ## Why a `UNION ALL` rather than two queries
  ///
  /// Takings come from `payments` and reversals from `refunds`, so there are two row sets to
  /// group. Reading them as two statements would mean the range filter and the settled-bill
  /// definition were applied twice and could drift; it would also let a method appear in one
  /// result and not the other. Unioning them into a single grouped pass keeps the `WITH`
  /// clause shared and produces one row per method carrying both figures, so a method that
  /// only ever had money taken back on it still appears.
  ///
  /// The two halves carry literal zeroes in each other's columns, which is what lets the
  /// outer `GROUP BY` add them without a `CASE` per column.
  @override
  Future<Result<PaymentMix>> loadPaymentMix(DateRange range) {
    return SqliteErrorMapper.guard<PaymentMix>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        ${_settledBillsCte()}
        SELECT
          movement.paymentMethod AS paymentMethod,
          COALESCE(SUM(movement.tenderCount), 0) AS tenderCount,
          COALESCE(SUM(movement.amountPaise), 0) AS amountPaise,
          COALESCE(SUM(movement.refundCount), 0) AS refundCount,
          COALESCE(SUM(movement.refundPaise), 0) AS refundPaise
        FROM (
          -- Money in.
          SELECT
            p.paymentMethod AS paymentMethod,
            COUNT(*) AS tenderCount,
            COALESCE(SUM(p.amountPaise), 0) AS amountPaise,
            0 AS refundCount,
            0 AS refundPaise
          FROM ${SqliteTables.payments} p
          JOIN settled o ON o.${SyncColumns.id} = p.orderId
          WHERE p.${SyncColumns.isDeleted} = 0 AND p.status = ?
          GROUP BY p.paymentMethod

          UNION ALL

          -- Money back out, by the method it came in on. Stored positive.
          SELECT
            r.paymentMethod AS paymentMethod,
            0 AS tenderCount,
            0 AS amountPaise,
            COUNT(*) AS refundCount,
            COALESCE(SUM(r.amountPaise), 0) AS refundPaise
          FROM ${SqliteTables.refunds} r
          JOIN settled o ON o.${SyncColumns.id} = r.orderId
          WHERE r.${SyncColumns.isDeleted} = 0 AND r.status = ?
          GROUP BY r.paymentMethod
        ) movement
        GROUP BY movement.paymentMethod
        ''',
        <Object?>[..._rangeArgs(range), _settledPayment, _settledRefund],
      );

      final Map<PaymentMethod, Money> amounts = <PaymentMethod, Money>{};
      final Map<PaymentMethod, int> counts = <PaymentMethod, int>{};
      final Map<PaymentMethod, Money> refunds = <PaymentMethod, Money>{};
      final Map<PaymentMethod, int> refundCounts = <PaymentMethod, int>{};

      for (final Map<String, Object?> row in rows) {
        final PaymentMethod method = row.requireEnum<PaymentMethod>(
          'paymentMethod',
          PaymentMethod.values,
          // A method name written by a newer build. Counted as `other` rather than
          // dropped, because the money was taken and has to appear somewhere.
          fallback: PaymentMethod.other,
        );

        // Accumulated rather than assigned: two unrecognised names would both land on
        // `other`, and the second must not overwrite the first.
        amounts[method] =
            (amounts[method] ?? Money.zero) +
            Money.fromPaise(row.optionalInt('amountPaise'));
        counts[method] = (counts[method] ?? 0) + row.optionalInt('tenderCount');
        refunds[method] =
            (refunds[method] ?? Money.zero) +
            Money.fromPaise(row.optionalInt('refundPaise'));
        refundCounts[method] =
            (refundCounts[method] ?? 0) + row.optionalInt('refundCount');
      }

      return PaymentMix(
        amounts: amounts,
        counts: counts,
        refunds: refunds,
        refundCounts: refundCounts,
      );
    }, context: 'total the payments');
  }

  /// Item-wise sales, in one grouped statement over the stored line snapshots.
  ///
  /// Grouped by the snapshot name and size, so a dish renamed since appears under the
  /// name it was sold as. `NULL` sizes group together, which is what a product with a
  /// single price should do.
  @override
  Future<Result<List<ItemSalesRow>>> loadItemSales(
    DateRange range, {
    int limit = 200,
  }) {
    return SqliteErrorMapper.guard<List<ItemSalesRow>>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        ${_settledBillsCte()}
        SELECT
          i.itemNameSnapshot AS itemName,
          i.variantNameSnapshot AS variantName,
          COALESCE(SUM(i.quantity), 0) AS quantitySold,
          COALESCE(SUM(i.totalAmountPaise), 0) AS salesPaise
        FROM ${SqliteTables.orderItems} i
        JOIN settled o ON o.${SyncColumns.id} = i.orderId
        WHERE i.${SyncColumns.isDeleted} = 0
        GROUP BY i.itemNameSnapshot, i.variantNameSnapshot
        -- Biggest earner first, which is the question this report is opened to answer.
        -- The name breaks a tie so the order is stable between runs.
        ORDER BY salesPaise DESC, quantitySold DESC, itemName ASC
        LIMIT ?
        ''',
        <Object?>[..._rangeArgs(range), limit],
      );

      return rows
          .map(
            (Map<String, Object?> row) => ItemSalesRow(
              itemName: row.requireString('itemName'),
              variantName: row.optionalString('variantName'),
              quantitySold: row.optionalInt('quantitySold'),
              salesAmount: Money.fromPaise(row.optionalInt('salesPaise')),
            ),
          )
          .toList(growable: false);
    }, context: 'total the item sales');
  }

  /// The settled bills in range, newest first, with everything the list shows.
  ///
  /// Four tables, one statement. The customer joins in; the payment method and the slip
  /// number come from scalar subqueries that each take the earliest matching row, which
  /// is the one the receipt printed.
  @override
  Future<Result<List<SalesBill>>> loadBills(
    DateRange range, {
    int limit = 200,
  }) {
    return SqliteErrorMapper.guard<List<SalesBill>>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        ${_settledBillsCte()}
        SELECT
          o.${SyncColumns.id} AS ${SyncColumns.id},
          o.${SyncColumns.createdAt} AS ${SyncColumns.createdAt},
          o.${SyncColumns.updatedAt} AS ${SyncColumns.updatedAt},
          o.${SyncColumns.isDeleted} AS ${SyncColumns.isDeleted},
          o.${SyncColumns.syncState} AS ${SyncColumns.syncState},
          o.orderNumber AS orderNumber,
          o.orderType AS orderType,
          o.status AS status,
          o.customerId AS customerId,
          o.subtotalPaise AS subtotalPaise,
          o.discountAmountPaise AS discountAmountPaise,
          o.taxAmountPaise AS taxAmountPaise,
          o.totalAmountPaise AS totalAmountPaise,
          -- The rate and the rule each bill was settled with, so a listed bill can state
          -- what it charged without the list reading today's configuration.
          o.taxRateBasisPoints AS taxRateBasisPoints,
          o.discountType AS discountType,
          o.discountValue AS discountValue,
          o.notes AS notes,
          c.phone AS customerPhone,
          COALESCE(o.customerName, c.name) AS customerName,
          -- The earliest settled tender, matching what the receipt printed. Split
          -- payment is a later feature and this is the line that changes for it.
          (
            SELECT p.paymentMethod
            FROM ${SqliteTables.payments} p
            WHERE p.orderId = o.${SyncColumns.id}
              AND p.${SyncColumns.isDeleted} = 0
              AND p.status = ?
            ORDER BY p.${SyncColumns.createdAt} ASC, p.rowid ASC
            LIMIT 1
          ) AS paymentMethod,
          -- The first slip raised for the bill: the number the counter called out.
          (
            SELECT k.kotNumber
            FROM ${SqliteTables.kotRecords} k
            WHERE k.orderId = o.${SyncColumns.id}
              AND k.${SyncColumns.isDeleted} = 0
            ORDER BY k.${SyncColumns.createdAt} ASC, k.rowid ASC
            LIMIT 1
          ) AS kotNumber,
          -- What has been handed back on this bill. The bill keeps its full total above,
          -- because it was rung up for that; this is how the list can say a reversal
          -- happened instead of showing a refunded bill as an ordinary sale.
          (
            SELECT COALESCE(SUM(r.amountPaise), 0)
            FROM ${SqliteTables.refunds} r
            WHERE r.orderId = o.${SyncColumns.id}
              AND r.${SyncColumns.isDeleted} = 0
              AND r.status = ?
          ) AS refundedPaise
        FROM settled o
        -- LEFT JOIN, so a walk-in bill with no customer still appears.
        LEFT JOIN ${SqliteTables.customers} c
          ON c.${SyncColumns.id} = o.customerId
          AND c.${SyncColumns.isDeleted} = 0
        -- Newest first. The order number breaks a tie between two bills recorded in the
        -- same millisecond: it is allocated in sequence, so it orders them as they were
        -- taken rather than arbitrarily.
        ORDER BY o.${SyncColumns.createdAt} DESC, o.orderNumber DESC
        LIMIT ?
        ''',
        // Bound in the order the statement reads: the CTE's three, then the tender status
        // for the payment-method subquery, then the refund status for the refunded-amount
        // subquery, then the limit.
        <Object?>[..._rangeArgs(range), _settledPayment, _settledRefund, limit],
      );

      return rows
          .map(
            (Map<String, Object?> row) => SalesBill(
              // The stored header, read by the same code that reads it anywhere else.
              order: Order.fromRow(row),
              paymentMethod: _methodOrNull(row),
              kotNumber: row.optionalString('kotNumber'),
              customerPhone: row.optionalString('customerPhone'),
              customerName: row.optionalString('customerName'),
              refundedAmount: Money.fromPaise(row.optionalInt('refundedPaise')),
            ),
          )
          .toList(growable: false);
    }, context: 'load the sales');
  }

  /// The settled bills matching [query], newest first, with everything the list shows.
  ///
  /// The same row as [loadBills] — the stored header, the earliest settled tender, the
  /// first slip number, the customer and anything refunded — narrowed by whichever of the
  /// four criteria the cashier supplied. The filters are composed into one `WHERE`, so a
  /// search is a single indexed statement rather than a scan in Dart.
  ///
  /// A bill number and a phone are matched anywhere within the stored value, so a partial
  /// entry still finds the bill. A phone search joins through the customer, which means a
  /// walk-in bill — one with no customer — is not a match, exactly as it should not be.
  @override
  Future<Result<List<SalesBill>>> searchBills(
    BillSearchQuery query, {
    int limit = 100,
  }) {
    return SqliteErrorMapper.guard<List<SalesBill>>(() async {
      // Bound in the order the statement reads them: the two subquery statuses first,
      // because the subqueries open the SELECT, then the WHERE filters, then the limit.
      final List<Object?> args = <Object?>[_settledPayment, _settledRefund];

      // Always a settled bill, exactly as every other read here. This is what keeps a
      // cancelled or unsettled record out of the history.
      final List<String> clauses = <String>['o.${SyncColumns.isDeleted} = 0'];
      clauses.add('o.status = ?');
      args.add(_settledOrder);

      final DateRange? range = query.range;
      if (range != null) {
        clauses.add('o.${SyncColumns.createdAt} >= ?');
        args.add(range.from.millisecondsSinceEpoch);
        clauses.add('o.${SyncColumns.createdAt} < ?');
        args.add(range.to.millisecondsSinceEpoch);
      }

      final String? orderNumberTerm = query.orderNumberTerm;
      if (orderNumberTerm != null) {
        // Matched anywhere within the number, so '0007' finds '20260913-0007'.
        clauses.add('o.orderNumber LIKE ? ESCAPE $_likeEscapeLiteral');
        args.add(_containsPattern(orderNumberTerm));
      }

      final OrderType? orderType = query.orderType;
      if (orderType != null) {
        clauses.add('o.orderType = ?');
        args.add(orderType.name);
      }

      final String? phoneTerm = query.customerPhoneTerm;
      if (phoneTerm != null) {
        // A filter on the joined customer's number. Because it is in the WHERE rather than
        // the join, it turns the LEFT JOIN into an inner match, which is what excludes a
        // walk-in bill from a phone search.
        clauses.add('c.phone LIKE ? ESCAPE $_likeEscapeLiteral');
        args.add(_containsPattern(phoneTerm));
      }

      args.add(limit);

      final List<Map<String, Object?>> rows = await _db.rawQuery('''
        SELECT
          o.${SyncColumns.id} AS ${SyncColumns.id},
          o.${SyncColumns.createdAt} AS ${SyncColumns.createdAt},
          o.${SyncColumns.updatedAt} AS ${SyncColumns.updatedAt},
          o.${SyncColumns.isDeleted} AS ${SyncColumns.isDeleted},
          o.${SyncColumns.syncState} AS ${SyncColumns.syncState},
          o.orderNumber AS orderNumber,
          o.orderType AS orderType,
          o.status AS status,
          o.customerId AS customerId,
          o.subtotalPaise AS subtotalPaise,
          o.discountAmountPaise AS discountAmountPaise,
          o.taxAmountPaise AS taxAmountPaise,
          o.totalAmountPaise AS totalAmountPaise,
          o.taxRateBasisPoints AS taxRateBasisPoints,
          o.discountType AS discountType,
          o.discountValue AS discountValue,
          o.notes AS notes,
          c.phone AS customerPhone,
          COALESCE(o.customerName, c.name) AS customerName,
          (
            SELECT p.paymentMethod
            FROM ${SqliteTables.payments} p
            WHERE p.orderId = o.${SyncColumns.id}
              AND p.${SyncColumns.isDeleted} = 0
              AND p.status = ?
            ORDER BY p.${SyncColumns.createdAt} ASC, p.rowid ASC
            LIMIT 1
          ) AS paymentMethod,
          (
            SELECT k.kotNumber
            FROM ${SqliteTables.kotRecords} k
            WHERE k.orderId = o.${SyncColumns.id}
              AND k.${SyncColumns.isDeleted} = 0
            ORDER BY k.${SyncColumns.createdAt} ASC, k.rowid ASC
            LIMIT 1
          ) AS kotNumber,
          (
            SELECT COALESCE(SUM(r.amountPaise), 0)
            FROM ${SqliteTables.refunds} r
            WHERE r.orderId = o.${SyncColumns.id}
              AND r.${SyncColumns.isDeleted} = 0
              AND r.status = ?
          ) AS refundedPaise
        FROM ${SqliteTables.orders} o
        LEFT JOIN ${SqliteTables.customers} c
          ON c.${SyncColumns.id} = o.customerId
          AND c.${SyncColumns.isDeleted} = 0
        WHERE ${clauses.join(' AND ')}
        ORDER BY o.${SyncColumns.createdAt} DESC, o.orderNumber DESC
        LIMIT ?
        ''', args);

      return rows
          .map(
            (Map<String, Object?> row) => SalesBill(
              order: Order.fromRow(row),
              paymentMethod: _methodOrNull(row),
              kotNumber: row.optionalString('kotNumber'),
              customerPhone: row.optionalString('customerPhone'),
              customerName: row.optionalString('customerName'),
              refundedAmount: Money.fromPaise(row.optionalInt('refundedPaise')),
            ),
          )
          .toList(growable: false);
    }, context: 'search the bills');
  }

  // --------------------------------------------------------------- internals ---

  /// A `LIKE` pattern matching [term] anywhere, with its own wildcards escaped.
  ///
  /// The user's text is data, not pattern: a bill number is unlikely to contain `%` or `_`,
  /// but escaping them means a stray one narrows the search rather than widening it to
  /// everything.
  static String _containsPattern(String term) {
    final String escaped = term
        .replaceAll(_likeEscape, '$_likeEscape$_likeEscape')
        .replaceAll('%', '$_likeEscape%')
        .replaceAll('_', '${_likeEscape}_');
    return '%$escaped%';
  }

  /// The character that escapes a `LIKE` wildcard, and its single-quoted SQL literal.
  static const String _likeEscape = r'\';
  static const String _likeEscapeLiteral = "'\\'";

  /// Names the settled bills in [range] as `settled`, for the statement that follows.
  ///
  /// Written once and shared by all four queries so they cannot disagree about which
  /// bills are sales. Takes three bound parameters, in the order [_rangeArgs] supplies
  /// them, and because the `WITH` clause opens the statement those are always the first
  /// three parameters bound.
  ///
  /// No `LIMIT` here: a limit belongs to the list being shown, not to the set being
  /// aggregated. Capping the bills query's totals would produce a summary that quietly
  /// stopped counting after two hundred bills.
  static String _settledBillsCte() =>
      '''
        WITH settled AS (
          SELECT
            ${SyncColumns.id},
            ${SyncColumns.createdAt},
            ${SyncColumns.updatedAt},
            ${SyncColumns.isDeleted},
            ${SyncColumns.syncState},
            orderNumber,
            orderType,
            status,
            customerId,
            subtotalPaise,
            discountAmountPaise,
            taxAmountPaise,
            totalAmountPaise,
            taxRateBasisPoints,
            discountType,
            discountValue,
            notes,
            customerName
          FROM ${SqliteTables.orders}
          WHERE ${SyncColumns.isDeleted} = 0
            AND status = ?
            AND ${SyncColumns.createdAt} >= ?
            AND ${SyncColumns.createdAt} < ?
        )''';

  /// The three parameters [_settledBillsCte] binds: the settled status, then the
  /// half-open instant bounds as stored UTC milliseconds.
  static List<Object?> _rangeArgs(DateRange range) => <Object?>[
    _settledOrder,
    range.from.millisecondsSinceEpoch,
    range.to.millisecondsSinceEpoch,
  ];

  /// The bill's settled tender method, or `null` when the subquery found none.
  ///
  /// `null` is a real answer here — a bill with no completed payment row — so it is
  /// distinguished from a stored value before the enum's fallback can turn it into
  /// `other`.
  static PaymentMethod? _methodOrNull(Map<String, Object?> row) {
    if (row['paymentMethod'] == null) {
      return null;
    }
    return row.requireEnum<PaymentMethod>(
      'paymentMethod',
      PaymentMethod.values,
      fallback: PaymentMethod.other,
    );
  }
}
