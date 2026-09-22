import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/payment.dart';
import '../../domain/models/payment_method.dart';
import '../../domain/models/payment_status.dart';
import '../../domain/repositories/payment_repository.dart';

/// SQLite implementation of [PaymentRepository].
class SqlitePaymentRepository implements PaymentRepository {
  SqlitePaymentRepository({required SqliteDatabase database})
    : _database = database,
      _payments = SqliteLocalStore<Payment>(
        database: database,
        table: SqliteTables.payments,
        fromRow: Payment.fromRow,
        orderBy: 'createdAt ASC',
      );

  final SqliteDatabase _database;
  final SqliteLocalStore<Payment> _payments;

  Database get _db => _database.database;

  @override
  Future<Result<void>> record(Payment payment) => _payments.save(payment);

  @override
  Future<Result<List<Payment>>> loadForOrder(String orderId) {
    return SqliteErrorMapper.guard<List<Payment>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.payments,
        where: 'orderId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderId],
        orderBy: 'createdAt ASC',
      );
      return rows.map(Payment.fromRow).toList(growable: false);
    }, context: 'load the payments');
  }

  @override
  Future<Result<Map<String, PaymentMethod>>> loadSettledMethodsForOrders(
    Iterable<String> orderIds,
  ) {
    return SqliteErrorMapper.guard<Map<String, PaymentMethod>>(() async {
      final List<String> ids = orderIds.toList(growable: false);
      if (ids.isEmpty) {
        return const <String, PaymentMethod>{};
      }

      final String placeholders = List<String>.filled(
        ids.length,
        '?',
      ).join(', ');
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.payments,
        columns: <String>['orderId', 'paymentMethod'],
        where: 'orderId IN ($placeholders) AND isDeleted = 0 AND status = ?',
        whereArgs: <Object?>[...ids, PaymentStatus.completed.name],
        // Earliest first, so `putIfAbsent` below keeps the first settled tender.
        orderBy: 'createdAt ASC, rowid ASC',
      );

      final Map<String, PaymentMethod> methods = <String, PaymentMethod>{};
      for (final Map<String, Object?> row in rows) {
        methods.putIfAbsent(
          row.requireString('orderId'),
          () => row.requireEnum<PaymentMethod>(
            'paymentMethod',
            PaymentMethod.values,
            // A method written by a newer build. Reported as `other` rather than
            // failing the whole read, which would blank a list of bills over one row.
            fallback: PaymentMethod.other,
          ),
        );
      }
      return methods;
    }, context: 'load how the bills were paid');
  }

  @override
  Future<Result<Money>> settledTotalForOrder(String orderId) {
    return SqliteErrorMapper.guard<Money>(() async {
      // Summed in SQL as integer paise, so the total is exact.
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        'SELECT COALESCE(SUM(amountPaise), 0) AS total '
        'FROM ${SqliteTables.payments} '
        'WHERE orderId = ? AND isDeleted = 0 AND status = ?',
        <Object?>[orderId, PaymentStatus.completed.name],
      );
      return Money.fromPaise((rows.first['total'] as int?) ?? 0);
    }, context: 'total the payments');
  }

  @override
  Future<Result<void>> updateStatusFor(String paymentId, Payment payment) =>
      _payments.save(payment);

  @override
  Future<Result<void>> delete(String id) => _payments.softDelete(id);

  /// Exposed for the sync layer: payments this terminal has not uploaded.
  Future<Result<List<Payment>>> loadUnsynced() => _payments.findUnsynced();

  /// Notifies watchers after a write made outside this repository.
  void notifyChanged() => _database.notifyTableChanged(SqliteTables.payments);
}
