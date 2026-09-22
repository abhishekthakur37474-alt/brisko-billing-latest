import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Adds the expenses table and new columns to the orders table for cancellation.
class M012ExpensesAndCancellation implements Migration {
  const M012ExpensesAndCancellation();

  @override
  int get version => 12;

  @override
  String get description => 'Expenses table and Order Cancellation fields';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    // Add columns to orders table
    await db.execute(
      'ALTER TABLE ${SqliteTables.orders} ADD COLUMN cancelledAt INTEGER',
    );
    await db.execute(
      'ALTER TABLE ${SqliteTables.orders} ADD COLUMN cancellationReason TEXT',
    );
    await db.execute(
      'ALTER TABLE ${SqliteTables.orders} ADD COLUMN authorizedBy TEXT',
    );

    // Create expenses table
    await db.execute('''
      CREATE TABLE ${SqliteTables.expenses} (
        ${SyncColumns.definition},
        name TEXT NOT NULL,
        amountPaise INTEGER NOT NULL,
        note TEXT
      )
    ''');
  }
}
