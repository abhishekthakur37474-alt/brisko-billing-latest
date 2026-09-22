import 'package:sqflite/sqflite.dart';

import '../../../sync/sync_state.dart';
import '../sqlite_tables.dart';
import 'migration.dart';

/// Requeues every previously-synced row so the terminal uploads it to Realtime
/// Database after leaving Cloud Firestore.
///
/// ## Why this exists
///
/// Cloud writes used to go to Firestore. Records already on the till are marked
/// `synced`, so the outbox would otherwise skip them and RTDB would never see
/// the menu or the existing bills. This migration flips those rows back to
/// `pending` and clears the pull cursor. The next sync cycle reconciles the
/// outbox and PATCHes each row under `restaurants/{uid}/…` in RTDB.
///
/// Soft-deleted rows are included: they still have to land in RTDB with
/// `isDeleted` set. Operational data is not rewritten otherwise — ids, prices
/// and timestamps stay as they are.
///
/// ## Additive and instant
///
/// Only `syncState` values and one bookmark row change. No schema, no seed, no
/// bill rewrite.
class M013RtdbResync implements Migration {
  const M013RtdbResync();

  @override
  int get version => 13;

  @override
  String get description =>
      'Requeue local records for Firebase Realtime Database';

  static const List<String> _syncedTables = <String>[
    SqliteTables.categories,
    SqliteTables.menuItems,
    SqliteTables.menuItemVariants,
    SqliteTables.menuItemOptions,
    SqliteTables.inventoryItems,
    SqliteTables.recipeIngredients,
    SqliteTables.stockMovements,
    SqliteTables.customers,
    SqliteTables.orders,
    SqliteTables.orderItems,
    SqliteTables.orderItemOptions,
    SqliteTables.payments,
    SqliteTables.refunds,
    SqliteTables.orderInventoryDeductions,
    SqliteTables.kotRecords,
    SqliteTables.kotItems,
    SqliteTables.kotItemOptions,
    SqliteTables.expenses,
  ];

  static const String _highWaterMarkKey = 'pull.highWaterMarkMillis';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String table in _syncedTables) {
      await db.rawUpdate(
        'UPDATE $table SET ${SyncColumns.syncState} = ? '
        'WHERE ${SyncColumns.syncState} = ?',
        <Object?>[SyncState.pending.name, SyncState.synced.name],
      );
    }
    await db.delete(
      SqliteTables.syncMetadata,
      where: 'key = ?',
      whereArgs: <Object?>[_highWaterMarkKey],
    );
  }
}
