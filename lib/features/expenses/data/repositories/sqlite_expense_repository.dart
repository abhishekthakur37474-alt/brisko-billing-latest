import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/expense.dart';
import '../../domain/repositories/expense_repository.dart';

class SqliteExpenseRepository implements ExpenseRepository {
  SqliteExpenseRepository({required this._database});

  final SqliteDatabase _database;

  Database get _db => _database.database;

  @override
  Future<Result<void>> save(Expense expense) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        await SqliteUpsert.run(
          txn,
          SqliteTables.expenses,
          expense.toMap(),
        );
      });
      _database.notifyTableChanged(SqliteTables.expenses);
    }, context: 'save expense');
  }

  @override
  Future<Result<List<Expense>>> loadToday() {
    return SqliteErrorMapper.guard<List<Expense>>(() async {
      final DateTime now = DateTime.now();
      final DateTime startOfDay = DateTime(now.year, now.month, now.day);
      final DateTime endOfDay = startOfDay.add(const Duration(days: 1));

      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.expenses,
        where: '${SyncColumns.isDeleted} = 0 '
            'AND ${SyncColumns.createdAt} >= ? '
            'AND ${SyncColumns.createdAt} < ?',
        whereArgs: <Object>[
          startOfDay.millisecondsSinceEpoch,
          endOfDay.millisecondsSinceEpoch,
        ],
        orderBy: '${SyncColumns.createdAt} DESC',
      );

      return rows.map(Expense.fromRow).toList(growable: false);
    }, context: 'load today expenses');
  }

  @override
  Future<Result<void>> delete(String id) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        await txn.update(
          SqliteTables.expenses,
          <String, Object?>{
            SyncColumns.isDeleted: 1,
            SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
            SyncColumns.syncState: 'pending',
          },
          where: '${SyncColumns.id} = ?',
          whereArgs: <Object>[id],
        );
      });
      _database.notifyTableChanged(SqliteTables.expenses);
    }, context: 'delete expense');
  }
}
