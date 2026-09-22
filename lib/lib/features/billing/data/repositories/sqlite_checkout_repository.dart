import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/utils/result.dart';
import '../../../customers/data/sqlite_customer_writer.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../kot/data/kot_number_sequence.dart';
import '../../../kot/data/sqlite_kot_writer.dart';
import '../../../kot/domain/models/kitchen_ticket_draft.dart';
import '../../../orders/data/order_number_sequence.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_item.dart';
import '../../../orders/domain/models/order_item_option.dart';
import '../../domain/models/bill_settlement.dart';
import '../../domain/repositories/checkout_repository.dart';

/// SQLite implementation of [CheckoutRepository].
class SqliteCheckoutRepository implements CheckoutRepository {
  SqliteCheckoutRepository({required this._database});

  /// Tables a settlement touches. Watchers on all of them are woken once it
  /// commits.
  static const List<String> _tables = <String>[
    SqliteTables.orders,
    SqliteTables.orderItems,
    SqliteTables.orderItemOptions,
    SqliteTables.payments,
    // A bill taken from a new customer creates their record in the same transaction,
    // so anything watching the customer list has to be woken too.
    SqliteTables.customers,
    ...SqliteKotWriter.tables,
  ];

  final SqliteDatabase _database;

  Database get _db => _database.database;

  @override
  Future<Result<Order>> settle(BillSettlement settlement) {
    return SqliteErrorMapper.guard<Order>(() async {
      _reject(settlement);

      // Normalised before the transaction opens, for two reasons. A number that cannot
      // be stored should refuse the sale before anything has been written, and
      // validation cannot happen inside the transaction: every future awaited in there
      // has to be a database operation, so a check that returns early without touching
      // the database would deadlock the settlement. See [SqliteCustomerWriter].
      final String? customerPhone = settlement.hasCustomer
          ? CustomerPhone.normalise(settlement.customerPhone!)
          : null;

      // Assigned inside the transaction and read after it commits, so the value
      // returned is the one that was written rather than one that was intended.
      late Order written;

      await _db.transaction((Transaction txn) async {
        await _rejectIfAlreadySettled(txn, settlement.orderId);

        // Allocated against the transaction, so a settlement that rolls back
        // consumes no number and the next bill reuses it.
        final String orderNumber = await OrderNumberSequence.next(
          txn,
          at: settlement.createdAt.toLocal(),
        );

        // Resolved here rather than before the transaction opened, so that a bill which
        // rolls back leaves no customer behind. A number already on file finds its
        // record; a new one is created; a walk-in has none and nothing is written.
        //
        // Idempotent, which is what makes a retry safe: the second attempt finds the
        // record the first one would have created, so one sale cannot produce two
        // customers.
        final String? customerId = customerPhone == null
            ? null
            : await SqliteCustomerWriter.resolve(
                txn,
                customerPhone,
                name: settlement.customerName,
              );

        final Order order = settlement.toOrder(
          orderNumber,
          customerId: customerId,
        );

        // Insert order in dependency order. Foreign keys are enforced
        // (PRAGMA foreign_keys = ON), so a line pointing at the wrong order, or a
        // payment pointing at no order, aborts the whole transaction here rather
        // than leaving a half-written bill behind.
        //
        // Every write is an upsert on `id`. A duplicate orderNumber therefore
        // raises a constraint error instead of replacing the bill that holds it,
        // and a retry of this same settlement rewrites its own rows.
        await SqliteUpsert.run(txn, SqliteTables.orders, order.toMap());

        for (final OrderItem item in settlement.items) {
          await SqliteUpsert.run(txn, SqliteTables.orderItems, item.toMap());
        }
        for (final OrderItemOption option in settlement.itemOptions) {
          await SqliteUpsert.run(
            txn,
            SqliteTables.orderItemOptions,
            option.toMap(),
          );
        }

        await SqliteUpsert.run(
          txn,
          SqliteTables.payments,
          settlement.payment.toMap(),
        );

        // The kitchen slip is part of the same commit as the money.
        //
        // The kitchen has no printer and no screen of its own, so this row is the
        // only record of what has to be cooked. Writing it afterwards, in its own
        // transaction, would leave a window in which the customer has paid and the
        // kitchen has been told nothing — and a failure in that window would be
        // invisible, because the bill would look complete. Inside the transaction, a
        // slip that cannot be written takes the order and the payment down with it,
        // and the cashier is told the sale did not go through.
        //
        // Allocated against the transaction, so a settlement that rolls back
        // consumes no slip number.
        final String kotNumber = await KotNumberSequence.next(
          txn,
          at: settlement.createdAt.toLocal(),
        );

        // Built from the order rows above, not from the menu. The slip can only say
        // what was sold.
        await SqliteKotWriter.write(
          txn,
          KitchenTicketDraft.fromOrder(
            order: order,
            items: settlement.items,
            itemOptions: settlement.itemOptions,
            kotNumber: kotNumber,
            kotId: settlement.kotId,
          ),
        );

        written = order;
      });

      // After the commit, never inside it: a watcher that read the tables mid
      // transaction would see a bill that might still roll back.
      _database.notifyTablesChanged(_tables);

      return written;
    }, context: 'complete the sale');
  }

  /// Refuses a bill that is already on disk.
  ///
  /// Every write here is an upsert, so a second settlement of the same bill would
  /// otherwise succeed quietly, reallocate the order number and overwrite the
  /// settled row. Nothing would be duplicated, but the bill the customer was given
  /// would no longer be the bill in the table.
  ///
  /// Refusing instead makes a double submission visible. It also stays correct for
  /// the case this is really protecting: after a failed settlement nothing was
  /// committed, so the id is absent and the retry goes through.
  static Future<void> _rejectIfAlreadySettled(
    Transaction txn,
    String orderId,
  ) async {
    final List<Map<String, Object?>> existing = await txn.query(
      SqliteTables.orders,
      columns: <String>['orderNumber'],
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      // ArgumentError so the error mapper reports it as a ValidationFailure
      // carrying this message, rather than as an unexpected fault.
      throw ArgumentError.value(
        orderId,
        'orderId',
        'This bill has already been settled as order '
            '${existing.first['orderNumber']}.',
      );
    }
  }

  /// Refuses a settlement the schema cannot refuse for us.
  ///
  /// Thrown rather than returned because it runs inside
  /// [SqliteErrorMapper.guard], which turns an [ArgumentError] into a
  /// `ValidationFailure`. That keeps one exit path for every way settlement can
  /// fail, so the caller handles a bad bill and a locked database the same way.
  static void _reject(BillSettlement settlement) {
    if (!settlement.hasLines) {
      throw ArgumentError.value(
        settlement.items.length,
        'items',
        'A bill needs at least one line before it can be settled',
      );
    }

    // The money block, checked before it becomes the historical record. Exact paise on
    // every side, so this is a real equality rather than a tolerance.
    if (!settlement.isArithmeticSound) {
      throw ArgumentError.value(
        settlement.amountPayable.toDecimalString(),
        'totals',
        'This bill does not add up: '
            '${settlement.totals.subtotal.toDecimalString()} less '
            '${settlement.totals.discount.toDecimalString()} discount plus '
            '${settlement.totals.tax.toDecimalString()} tax is not '
            '${settlement.totals.total.toDecimalString()}',
      );
    }

    if (!settlement.isBalanced) {
      throw ArgumentError.value(
        settlement.payment.amount.toDecimalString(),
        'payment',
        'The payment must equal the bill total of '
            '${settlement.amountPayable.toDecimalString()}',
      );
    }
  }
}
