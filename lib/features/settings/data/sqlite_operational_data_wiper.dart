import 'package:sqflite/sqflite.dart';

import '../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../core/data/local/sqlite/sqlite_outbox_store.dart';
import '../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../core/data/remote/firebase/firebase_auth_session.dart';
import '../../../core/data/remote/firebase/rtdb_rest_client.dart';
import '../../../core/data/sync/sync_coordinator.dart';
import '../../../core/utils/result.dart';
import '../domain/models/setting_keys.dart';
import '../domain/models/till_backup.dart';
import '../domain/repositories/settings_repository.dart';
import '../domain/services/operational_data_wiper.dart';
import '../domain/services/till_backup_store.dart';

/// SQLite (and optional RTDB) implementation of [OperationalDataWiper].
///
/// ## What is removed
///
/// Every table that feeds a bill, a kitchen slip, a report or the dashboard,
/// including the menu. Rows are physically deleted rather than soft-deleted, so
/// the till looks empty afterwards rather than full of hidden history. When an
/// [RtdbRestClient] is supplied, the signed-in restaurant node is deleted too.
///
/// ## What is kept
///
/// [SqliteTables.settings] holds the sign-in, the outlet, the printer and the
/// manager password. [SqliteTables.syncMetadata] is left so an ordinary pull
/// does not dump the entire cloud history back onto a just-cleared till — and
/// after an RTDB wipe there is nothing to dump anyway.
///
/// ## Backup first
///
/// A JSON snapshot of the local tables and the restaurant node is written before
/// any delete. The path and timestamps are stored in settings so Settings can
/// offer a download and show when the last backup and last clear happened.
///
/// ## Foreign keys
///
/// Child tables are emptied before their parents, matching `ON DELETE RESTRICT`.
/// The local wipe is one transaction, so a fault leaves the previous data intact.
class SqliteOperationalDataWiper implements OperationalDataWiper {
  const SqliteOperationalDataWiper({
    required this.database,
    required this.outbox,
    required this.settings,
    required this.backups,
    this.rtdb,
    this.syncCoordinator,
  });

  final SqliteDatabase database;

  final SqliteOutboxStore outbox;

  final SettingsRepository settings;

  final TillBackupStore backups;

  /// Present on a cloud build. Absent on a local-only till, which only wipes SQLite.
  final RtdbRestClient? rtdb;

  /// Paused around the wipe so a pull cannot race the local delete.
  final SyncCoordinator? syncCoordinator;

  /// Child-before-parent order. [SqliteTables.settings] and
  /// [SqliteTables.syncMetadata] are deliberately absent.
  static const List<String> tablesInDeleteOrder = <String>[
    SqliteTables.kotItemOptions,
    SqliteTables.kotItems,
    SqliteTables.kotRecords,
    SqliteTables.orderItemOptions,
    SqliteTables.refunds,
    SqliteTables.payments,
    SqliteTables.orderInventoryDeductions,
    SqliteTables.orderItems,
    SqliteTables.orders,
    SqliteTables.heldBillLineOptions,
    SqliteTables.heldBillLines,
    SqliteTables.heldBills,
    SqliteTables.recipeIngredients,
    SqliteTables.stockMovements,
    SqliteTables.menuItemOptions,
    SqliteTables.menuItemVariants,
    SqliteTables.menuItems,
    SqliteTables.categories,
    SqliteTables.inventoryItems,
    SqliteTables.customers,
    SqliteTables.expenses,
    SqliteTables.outbox,
  ];

  @override
  Future<Result<void>> clearOperationalData() async {
    final SyncCoordinator? coordinator = syncCoordinator;
    final bool resumeSync = coordinator?.isStarted ?? false;
    if (coordinator != null) {
      await coordinator.stop();
    }

    try {
      final DateTime now = DateTime.now().toUtc();

      final Result<Map<String, Object?>> sqliteDump = await _dumpSqlite();
      if (sqliteDump.isErr) {
        return Err<void>(sqliteDump.failureOrNull!);
      }

      Map<String, Object?> rtdbDump = const <String, Object?>{};
      String? restaurantId;
      final RtdbRestClient? cloud = rtdb;
      if (cloud != null) {
        final Result<FirebaseAuthContext> auth = await cloud.session.current();
        if (auth.isErr) {
          return Err<void>(auth.failureOrNull!);
        }
        restaurantId = auth.valueOrNull?.restaurantId;
        final Result<Map<String, Object?>> cloudDump = await cloud.getRestaurant();
        if (cloudDump.isErr) {
          return Err<void>(cloudDump.failureOrNull!);
        }
        rtdbDump = cloudDump.valueOrNull ?? const <String, Object?>{};
      }

      final Result<TillBackup> saved = await backups.save(
        createdAt: now,
        sqlite: sqliteDump.valueOrNull!,
        rtdb: rtdbDump,
        restaurantId: restaurantId,
      );
      if (saved.isErr) {
        return Err<void>(saved.failureOrNull!);
      }
      final TillBackup backup = saved.valueOrNull!;

      if (cloud != null) {
        final Result<void> deleted = await cloud.deleteRestaurant();
        if (deleted.isErr) {
          return deleted;
        }
      }

      final Result<void> local = await _wipeLocal();
      if (local.isErr) {
        return local;
      }

      final Result<void> stamped = await settings.writeAll(<String, String?>{
        SettingKeys.lastBackupAt: now.millisecondsSinceEpoch.toString(),
        SettingKeys.lastBackupPath: backup.filePath,
        SettingKeys.lastClearedAt: now.millisecondsSinceEpoch.toString(),
      });
      if (stamped.isErr) {
        return stamped;
      }

      return const Ok<void>(null);
    } finally {
      if (resumeSync) {
        coordinator!.start();
      }
    }
  }

  Future<Result<void>> _wipeLocal() {
    return SqliteErrorMapper.guard<void>(() async {
      await database.database.transaction((Transaction txn) async {
        for (final String table in tablesInDeleteOrder) {
          await txn.delete(table);
        }
      });

      await outbox.clearAll();
      database.notifyTablesChanged(tablesInDeleteOrder);
    }, context: 'clear the till data');
  }

  Future<Result<Map<String, Object?>>> _dumpSqlite() {
    return SqliteErrorMapper.guard<Map<String, Object?>>(() async {
      final Map<String, Object?> tables = <String, Object?>{};
      for (final String table in tablesInDeleteOrder) {
        if (table == SqliteTables.outbox) {
          continue;
        }
        tables[table] = await database.database.query(table);
      }
      return tables;
    }, context: 'read the till for backup');
  }
}
