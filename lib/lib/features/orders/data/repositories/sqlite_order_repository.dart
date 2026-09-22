import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/utils/result.dart';
import '../../../kot/domain/models/kot_status.dart';
import '../../domain/models/bill_line_snapshot.dart';
import '../../domain/models/order.dart';
import '../../domain/models/order_cancellation.dart';
import '../../domain/models/order_item.dart';
import '../../domain/models/order_item_option.dart';
import '../../domain/models/order_status.dart';
import '../../domain/repositories/order_repository.dart';
import '../order_number_sequence.dart';

/// SQLite implementation of [OrderRepository].
class SqliteOrderRepository implements OrderRepository {
  SqliteOrderRepository({required SqliteDatabase database})
    : _database = database,
      _orders = SqliteLocalStore<Order>(
        database: database,
        table: SqliteTables.orders,
        fromRow: Order.fromRow,
        orderBy: 'createdAt DESC',
      );

  final SqliteDatabase _database;
  final SqliteLocalStore<Order> _orders;

  Database get _db => _database.database;

  @override
  Future<Result<void>> saveOrder(
    Order order, {
    List<OrderItem> items = const <OrderItem>[],
    List<OrderItemOption> itemOptions = const <OrderItemOption>[],
  }) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        // Upsert on id only. A collision on the unique orderNumber must fail
        // rather than replace, because replacing would delete a settled bill.
        await SqliteUpsert.run(txn, SqliteTables.orders, order.toMap());
        for (final OrderItem item in items) {
          await SqliteUpsert.run(txn, SqliteTables.orderItems, item.toMap());
        }
        for (final OrderItemOption option in itemOptions) {
          await SqliteUpsert.run(
            txn,
            SqliteTables.orderItemOptions,
            option.toMap(),
          );
        }
      });

      _database.notifyTablesChanged(const <String>[
        SqliteTables.orders,
        SqliteTables.orderItems,
        SqliteTables.orderItemOptions,
      ]);
    }, context: 'save the order');
  }

  @override
  Future<Result<Order?>> findOrder(String id) => _orders.findById(id);

  @override
  Future<Result<Order?>> findOrderByNumber(String orderNumber) {
    return SqliteErrorMapper.guard<Order?>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orders,
        where: 'orderNumber = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderNumber],
        limit: 1,
      );
      return rows.isEmpty ? null : Order.fromRow(rows.first);
    }, context: 'find the order');
  }

  /// Lines and their options are ordered by `createdAt` and then by SQLite's
  /// implicit `rowid`.
  ///
  /// The `rowid` tiebreak matters: several lines added within the same millisecond
  /// share a `createdAt`, and entity ids carry random entropy, so ordering by id
  /// would shuffle them arbitrarily. `rowid` increases with each insert, so it
  /// reproduces the exact sequence the cashier entered. A receipt whose lines
  /// reorder between prints looks wrong to the customer even when the total is
  /// right.
  @override
  Future<Result<List<OrderItem>>> loadItems(String orderId) {
    return SqliteErrorMapper.guard<List<OrderItem>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orderItems,
        where: 'orderId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(OrderItem.fromRow).toList(growable: false);
    }, context: 'load the order lines');
  }

  @override
  Future<Result<List<OrderItemOption>>> loadItemOptions(String orderItemId) {
    return SqliteErrorMapper.guard<List<OrderItemOption>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orderItemOptions,
        where: 'orderItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderItemId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(OrderItemOption.fromRow).toList(growable: false);
    }, context: 'load the line options');
  }

  /// The bill's lines with their options attached, in the sequence they were entered.
  ///
  /// Two queries rather than one per line: the options for every line on the bill are
  /// read in a single pass and then grouped in memory. A bill with fifteen lines is two
  /// reads, not sixteen.
  ///
  /// Nothing here touches the menu tables. Every column read is a snapshot written when
  /// the bill was settled.
  @override
  Future<Result<List<BillLineSnapshot>>> loadBillLines(String orderId) {
    return SqliteErrorMapper.guard<List<BillLineSnapshot>>(() async {
      final List<Map<String, Object?>> lineRows = await _db.query(
        SqliteTables.orderItems,
        where: 'orderId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderId],
        orderBy: 'createdAt ASC, rowid ASC',
      );

      if (lineRows.isEmpty) {
        return const <BillLineSnapshot>[];
      }

      final List<OrderItem> items = lineRows
          .map(OrderItem.fromRow)
          .toList(growable: false);

      final List<Map<String, Object?>> optionRows = await _db.query(
        SqliteTables.orderItemOptions,
        where:
            'orderItemId IN (${_placeholders(items.length)}) AND isDeleted = 0',
        whereArgs: items.map((OrderItem item) => item.id).toList(),
        orderBy: 'createdAt ASC, rowid ASC',
      );

      final Map<String, List<OrderItemOption>> byLine =
          <String, List<OrderItemOption>>{};
      for (final Map<String, Object?> row in optionRows) {
        final OrderItemOption option = OrderItemOption.fromRow(row);
        byLine
            .putIfAbsent(option.orderItemId, () => <OrderItemOption>[])
            .add(option);
      }

      return items
          .map(
            (OrderItem item) => BillLineSnapshot(
              item: item,
              options: byLine[item.id] ?? const <OrderItemOption>[],
            ),
          )
          .toList(growable: false);
    }, context: 'load the bill');
  }

  @override
  Future<Result<Map<String, List<OrderItem>>>> loadItemsForOrders(
    Iterable<String> orderIds,
  ) {
    return SqliteErrorMapper.guard<Map<String, List<OrderItem>>>(() async {
      final List<String> ids = orderIds.toList(growable: false);
      if (ids.isEmpty) {
        return const <String, List<OrderItem>>{};
      }

      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orderItems,
        where: 'orderId IN (${_placeholders(ids.length)}) AND isDeleted = 0',
        whereArgs: ids,
        orderBy: 'createdAt ASC, rowid ASC',
      );

      final Map<String, List<OrderItem>> grouped = <String, List<OrderItem>>{};
      for (final Map<String, Object?> row in rows) {
        final OrderItem item = OrderItem.fromRow(row);
        grouped.putIfAbsent(item.orderId, () => <OrderItem>[]).add(item);
      }
      return grouped;
    }, context: 'load the bill lines');
  }

  @override
  Future<Result<List<Order>>> loadOrders({
    DateTime? from,
    DateTime? to,
    OrderStatus? status,
    int limit = 200,
  }) {
    return SqliteErrorMapper.guard<List<Order>>(() async {
      final List<String> clauses = <String>['isDeleted = 0'];
      final List<Object?> args = <Object?>[];

      if (from != null) {
        clauses.add('createdAt >= ?');
        args.add(from.toUtc().millisecondsSinceEpoch);
      }
      if (to != null) {
        clauses.add('createdAt < ?');
        args.add(to.toUtc().millisecondsSinceEpoch);
      }
      if (status != null) {
        clauses.add('status = ?');
        args.add(status.name);
      }

      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orders,
        where: clauses.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'createdAt DESC',
        limit: limit,
      );
      return rows.map(Order.fromRow).toList(growable: false);
    }, context: 'load orders');
  }

  @override
  Future<Result<List<Order>>> loadOrdersForCustomer(
    String customerId, {
    int limit = 200,
  }) {
    return SqliteErrorMapper.guard<List<Order>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orders,
        where: 'customerId = ? AND isDeleted = 0',
        whereArgs: <Object?>[customerId],
        orderBy: 'createdAt DESC',
        limit: limit,
      );
      return rows.map(Order.fromRow).toList(growable: false);
    }, context: 'load the customer order history');
  }

  /// Reads the next number without reserving it.
  ///
  /// Nothing is written, so the number is only good until someone inserts an order.
  /// That is fine for showing a cashier what the next bill will be called, and it is
  /// deliberately not how settlement allocates: [OrderNumberSequence.next] is called
  /// there with the settlement's own transaction, so allocation and insert commit
  /// together.
  @override
  Future<Result<String>> nextOrderNumber() {
    return SqliteErrorMapper.guard<String>(
      () => OrderNumberSequence.next(_db),
      context: 'allocate an order number',
    );
  }

  @override
  Future<Result<void>> updateStatus(String orderId, OrderStatus status) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.update(
        SqliteTables.orders,
        <String, Object?>{
          'status': status.name,
          SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          // The change has not reached any backend yet.
          SyncColumns.syncState: SyncState.pending.name,
        },
        where: '${SyncColumns.id} = ?',
        whereArgs: <Object?>[orderId],
      );
      _database.notifyTableChanged(SqliteTables.orders);
    }, context: 'update the order status');
  }

  /// Cancels the bill and stops any outstanding kitchen work, in one transaction.
  ///
  /// ## The whole of it is a status change
  ///
  /// Two `UPDATE`s: the order's status, and the status of its slips that are still
  /// outstanding. Nothing is deleted, no amount is rewritten and `createdAt` is
  /// untouched, so the bill stays readable and auditable exactly as it was settled. The
  /// figures stop counting it because reports and customer totals already filter on
  /// `OrderStatus.completed`, not because anything here adjusts them.
  ///
  /// The slips are moved in the same transaction as the order, for the same reason
  /// settlement writes them with the money: a committed cancellation that left the
  /// kitchen still cooking would be invisible, because the bill would look correctly
  /// cancelled.
  ///
  /// ## One winner
  ///
  /// The status is re-read inside the transaction and the move is refused if it is not
  /// legal from what was read. On the single SQLite connection the application uses,
  /// transactions are serialised, so of two simultaneous cancellations the second sees
  /// the first's committed status and is turned away.
  @override
  Future<Result<Order>> cancelOrder(
    String orderId, {
    String? cancellationReason,
    String? authorizedBy,
  }) {
    return SqliteErrorMapper.guard<Order>(() async {
      await _db.transaction((Transaction txn) async {
        await _refuseIfNotCancellable(txn, orderId);

        final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

        await txn.update(
          SqliteTables.orders,
          <String, Object?>{
            'status': OrderCancellation.cancelledStatus.name,
            'cancelledAt': now,
            'cancellationReason': cancellationReason,
            'authorizedBy': authorizedBy,
            SyncColumns.updatedAt: now,
            // The status change is itself a change no backend has seen.
            SyncColumns.syncState: SyncState.pending.name,
          },
          where: '${SyncColumns.id} = ?',
          whereArgs: <Object?>[orderId],
        );

        await _cancelOutstandingKots(txn, orderId, at: now);
      });

      // After the commit, never inside it.
      _database.notifyTablesChanged(const <String>[
        SqliteTables.orders,
        SqliteTables.kotRecords,
      ]);

      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orders,
        where: '${SyncColumns.id} = ?',
        whereArgs: <Object?>[orderId],
        limit: 1,
      );
      if (rows.isEmpty) {
        // Cannot happen: the row was just updated inside a committed transaction.
        // Guarded so a caller never unwraps a null.
        throw StateError('The bill disappeared after being cancelled.');
      }
      return Order.fromRow(rows.first);
    }, context: 'cancel the bill');
  }

  @override
  Future<Result<void>> deleteOrder(String id) => _orders.softDelete(id);

  /// Refuses a bill that is not there, or that has already been cancelled.
  ///
  /// Reads the stored status inside the caller's transaction, so the status the move is
  /// checked against is the status the move is applied to.
  ///
  /// [ArgumentError] rather than a returned failure, because [SqliteErrorMapper.guard]
  /// turns one into a `ValidationFailure` carrying this message. A missing bill and a
  /// second cancellation are both recoverable: the screen reloads and shows the cashier
  /// the real state.
  Future<void> _refuseIfNotCancellable(Transaction txn, String orderId) async {
    final List<Map<String, Object?>> rows = await txn.query(
      SqliteTables.orders,
      columns: <String>['status'],
      where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[orderId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        orderId,
        'orderId',
        'That bill is no longer on this terminal.',
      );
    }

    final OrderStatus current = rows.first.requireEnum<OrderStatus>(
      'status',
      OrderStatus.values,
      // A status written by a newer build reads as cancelled rather than as live, so a
      // bill this build cannot account for is refused rather than quietly rewritten.
      fallback: OrderCancellation.cancelledStatus,
    );

    final String? refusal = OrderCancellation.refusalReason(current);
    if (refusal != null) {
      throw ArgumentError.value(orderId, 'orderId', refusal);
    }
  }

  /// Moves the bill's outstanding kitchen slips to cancelled, leaving finished ones.
  ///
  /// Only the states named on [OrderCancellation.cancellableKotStatuses] are touched. A
  /// completed slip is left completed, because the food was made and handed over and
  /// rewriting it would claim otherwise. The slips' lines are not touched at all, so what
  /// was asked for stays answerable after the bill is cancelled.
  Future<void> _cancelOutstandingKots(
    Transaction txn,
    String orderId, {
    required int at,
  }) async {
    const List<KotStatus> cancellable =
        OrderCancellation.cancellableKotStatuses;

    await txn.update(
      SqliteTables.kotRecords,
      <String, Object?>{
        'status': KotStatus.cancelled.name,
        SyncColumns.updatedAt: at,
        SyncColumns.syncState: SyncState.pending.name,
      },
      where:
          'orderId = ? AND ${SyncColumns.isDeleted} = 0 '
          'AND status IN (${_placeholders(cancellable.length)})',
      whereArgs: <Object?>[
        orderId,
        ...cancellable.map((KotStatus status) => status.name),
      ],
    );
  }

  /// `?, ?, ?` for an `IN` clause of [count] values.
  ///
  /// Placeholders rather than interpolated ids. The values are database-generated and
  /// could not carry anything harmful, but building SQL by concatenating values is a
  /// habit that eventually meets a value that can.
  static String _placeholders(int count) =>
      List<String>.filled(count, '?').join(', ');
}
