import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order_status.dart';
import '../../../payments/domain/models/refund_policy.dart';
import '../../domain/models/customer.dart';
import '../../domain/models/customer_phone.dart';
import '../../domain/models/customer_summary.dart';
import '../../domain/repositories/customer_repository.dart';
import '../sqlite_customer_writer.dart';

/// SQLite implementation of [CustomerRepository].
///
/// ## Why the summary queries read the orders table
///
/// A customer's order count and spend are facts about their bills, and the only place
/// those facts exist is `orders`. The alternative — asking `OrderRepository` per
/// customer — is one query per row on the directory screen, and it still could not
/// produce the aggregate in a single read. So the join lives here, in the data layer,
/// where SQL belongs. Nothing above this file knows the two tables were joined, and
/// these are reads: no order row is ever written from the customers module.
class SqliteCustomerRepository implements CustomerRepository {
  SqliteCustomerRepository({required SqliteDatabase database})
    : _database = database,
      _customers = SqliteLocalStore<Customer>(
        database: database,
        table: SqliteTables.customers,
        fromRow: Customer.fromRow,
        orderBy: 'name ASC, phone ASC',
      );

  /// Orders that count as a visit. Settled bills only; see [CustomerSummary].
  static final String _countedStatus = OrderStatus.completed.name;

  /// Refunds that count against a customer's spend: those whose money has actually gone
  /// back. The same rule the sales report applies. See `RefundPolicy`.
  static final String _settledRefundStatus =
      RefundPolicy.completedRefundStatus.name;

  final SqliteDatabase _database;
  final SqliteLocalStore<Customer> _customers;

  Database get _db => _database.database;

  @override
  Future<Result<Customer?>> findByPhone(String phone) {
    return SqliteErrorMapper.guard<Customer?>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.customers,
        where: 'phone = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[_lookupKey(phone)],
        // Oldest first, so a duplicate created later never shadows the record that
        // carries the longer history.
        orderBy: '${SyncColumns.createdAt} ASC',
        limit: 1,
      );
      return rows.isEmpty ? null : Customer.fromRow(rows.first);
    }, context: 'find the customer');
  }

  @override
  Future<Result<Customer?>> findById(String id) => _customers.findById(id);

  @override
  Future<Result<List<Customer>>> search(String query, {int limit = 25}) {
    return SqliteErrorMapper.guard<List<Customer>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.customers,
        where: '${SyncColumns.isDeleted} = 0 AND (phone LIKE ? OR name LIKE ?)',
        whereArgs: _searchPatterns(query),
        orderBy: 'name ASC, phone ASC',
        limit: limit,
      );
      return rows.map(Customer.fromRow).toList(growable: false);
    }, context: 'search customers');
  }

  @override
  Future<Result<List<Customer>>> loadAll() => _customers.findAll();

  @override
  Future<Result<void>> save(Customer customer) => _customers.save(customer);

  @override
  Future<Result<Customer>> findOrCreateByPhone(String phone, {String? name}) {
    return SqliteErrorMapper.guard<Customer>(() async {
      // Validated before the transaction opens. An unusable number is refused here
      // rather than inside the transaction, both because nothing should be written for
      // it and because a check that returns without touching the database would deadlock
      // the transaction. See [SqliteCustomerWriter].
      final String normalised = CustomerPhone.normalise(phone);

      // Lookup and insert in one transaction so two rapid entries of the same number
      // cannot both decide the customer is missing.
      final Customer customer = await _db.transaction<Customer>((
        Transaction txn,
      ) async {
        final String id = await SqliteCustomerWriter.resolve(
          txn,
          normalised,
          name: name,
        );

        final List<Map<String, Object?>> rows = await txn.query(
          SqliteTables.customers,
          where: '${SyncColumns.id} = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        return Customer.fromRow(rows.single);
      });

      _database.notifyTableChanged(SqliteTables.customers);
      return customer;
    }, context: 'save the customer');
  }

  /// One grouped read: every matching customer, with their settled bill count, their
  /// spend and the date of their last visit.
  ///
  /// The join is a `LEFT JOIN`, so a customer who has not ordered yet appears with
  /// zeroes rather than vanishing. `SUM` runs over the `INTEGER` paise column and comes
  /// back an integer, so the total is exact and no decimal is ever parsed.
  @override
  Future<Result<List<CustomerSummary>>> loadDirectory({
    String? query,
    int limit = 100,
  }) {
    return SqliteErrorMapper.guard<List<CustomerSummary>>(() async {
      final bool isFiltered = query != null && query.trim().isNotEmpty;

      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        SELECT ${_summaryColumns()}
        FROM ${SqliteTables.customers} c
        ${_summaryJoin()}
        WHERE c.${SyncColumns.isDeleted} = 0
        ${isFiltered ? 'AND (c.phone LIKE ? OR c.name LIKE ?)' : ''}
        GROUP BY c.${SyncColumns.id}
        -- Most recent visit first, because that is who the counter is asking about.
        -- Customers with no bills sort last rather than first, which they otherwise
        -- would: a NULL lastOrderAt is not a recent visit.
        ORDER BY (lastOrderAt IS NULL) ASC, lastOrderAt DESC, c.phone ASC
        LIMIT ?
        ''',
        // In statement order: the refund status inside the column list, then the order
        // status in the join, then the search patterns, then the limit.
        <Object?>[
          _settledRefundStatus,
          _countedStatus,
          if (isFiltered) ..._searchPatterns(query),
          limit,
        ],
      );

      return rows.map(_summaryOf).toList(growable: false);
    }, context: 'load the customer list');
  }

  @override
  Future<Result<CustomerSummary?>> loadSummary(String customerId) {
    return SqliteErrorMapper.guard<CustomerSummary?>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        SELECT ${_summaryColumns()}
        FROM ${SqliteTables.customers} c
        ${_summaryJoin()}
        WHERE c.${SyncColumns.id} = ? AND c.${SyncColumns.isDeleted} = 0
        GROUP BY c.${SyncColumns.id}
        ''',
        // In statement order: the refund status inside the column list, then the order
        // status in the join, then the customer id.
        <Object?>[_settledRefundStatus, _countedStatus, customerId],
      );

      return rows.isEmpty ? null : _summaryOf(rows.first);
    }, context: 'load the customer summary');
  }

  @override
  Future<Result<void>> delete(String id) => _customers.softDelete(id);

  // --------------------------------------------------------------- internals ---

  /// Columns the two summary queries share, so they cannot describe a customer
  /// differently.
  ///
  /// The customer's own columns are listed rather than `c.*` so the row is exactly what
  /// [Customer.fromRow] expects, with the four aggregates alongside it.
  ///
  /// ## The refunded figure is a correlated subquery, not a second join
  ///
  /// A `LEFT JOIN refunds` would be shorter and would work today, because at most one
  /// reversal can exist per bill. It would also be a trap: the moment partial refunds allow
  /// two rows against one bill, the join would duplicate that bill's row and
  /// `SUM(o.totalAmountPaise)` would silently double-count what the customer spent. The
  /// subquery collapses to one value per bill whatever the schema later allows, so this
  /// query cannot be broken from a distance.
  ///
  /// ## Bound parameters
  ///
  /// Takes one parameter, the settled refund status, and it comes **first** in both
  /// statements below because SQLite binds by position and the column list is written before
  /// the join. [_summaryJoin] takes the second. Getting these the wrong way round would
  /// compare a status to a status and return zeroes rather than fail, so the order is stated
  /// here and asserted by the customer tests.
  static String _summaryColumns() =>
      '''
        c.${SyncColumns.id} AS ${SyncColumns.id},
        c.${SyncColumns.createdAt} AS ${SyncColumns.createdAt},
        c.${SyncColumns.updatedAt} AS ${SyncColumns.updatedAt},
        c.${SyncColumns.isDeleted} AS ${SyncColumns.isDeleted},
        c.${SyncColumns.syncState} AS ${SyncColumns.syncState},
        c.name AS name,
        c.phone AS phone,
        COUNT(o.${SyncColumns.id}) AS orderCount,
        COALESCE(SUM(o.totalAmountPaise), 0) AS totalSpentPaise,
        COALESCE(SUM(
          (SELECT COALESCE(SUM(r.amountPaise), 0)
           FROM ${SqliteTables.refunds} r
           WHERE r.orderId = o.${SyncColumns.id}
             AND r.${SyncColumns.isDeleted} = 0
             AND r.status = ?)
        ), 0) AS refundedPaise,
        MAX(o.${SyncColumns.createdAt}) AS lastOrderAt''';

  /// The counted-orders join.
  ///
  /// The status and soft-delete tests are in the `ON` clause rather than the `WHERE`
  /// clause on purpose: in a `WHERE` they would turn this into an inner join and drop
  /// every customer who has not ordered yet.
  static String _summaryJoin() =>
      '''
        LEFT JOIN ${SqliteTables.orders} o
          ON o.customerId = c.${SyncColumns.id}
          AND o.${SyncColumns.isDeleted} = 0
          AND o.status = ?''';

  static CustomerSummary _summaryOf(Map<String, Object?> row) {
    final Object? lastOrderAt = row['lastOrderAt'];

    return CustomerSummary(
      customer: Customer.fromRow(row),
      completedOrderCount: (row['orderCount'] as int?) ?? 0,
      // Straight from an integer column. No parsing, no rounding, no double.
      totalSpent: Money.fromPaise((row['totalSpentPaise'] as int?) ?? 0),
      refundedTotal: Money.fromPaise((row['refundedPaise'] as int?) ?? 0),
      lastOrderAt: lastOrderAt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastOrderAt, isUtc: true)
          : null,
    );
  }

  /// What to match a stored phone number against.
  ///
  /// Normalised when the input reduces to a valid number, so `+91 98765 43210` finds
  /// `9876543210`. Otherwise the trimmed input is used as given: a lookup for something
  /// that is not a valid number should miss quietly, and a record written before these
  /// rules existed should still be findable by exactly what it holds.
  static String _lookupKey(String phone) =>
      CustomerPhone.tryNormalise(phone) ?? phone.trim();

  /// `LIKE` patterns for a free-text search: digits against the phone, text against the
  /// name.
  ///
  /// Three cases, in order:
  ///
  /// * A query that is a complete number is normalised, so pasting
  ///   `+91 98765 43210` finds the stored `9876543210` rather than searching for the
  ///   country code as if it were part of the number.
  /// * Otherwise the digits are used as typed, so `98765 4` still narrows towards
  ///   `9876543210` while it is being entered.
  /// * A query with no digits at all is used verbatim. It will not match a phone number,
  ///   which is correct — the alternative, an empty pattern, would become `%%` and match
  ///   every customer.
  static List<Object?> _searchPatterns(String query) {
    final String trimmed = query.trim();
    final String? normalised = CustomerPhone.tryNormalise(trimmed);
    final String digits = trimmed.replaceAll(RegExp(r'\D'), '');
    final String phonePattern =
        normalised ?? (digits.isEmpty ? trimmed : digits);
    return <Object?>['%$phonePattern%', '%$trimmed%'];
  }
}
