import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m005_kot_order_snapshots.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m006_recipes_and_stock_deduction.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m007_held_bills.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m008_refunds.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m009_bill_tax_and_discount.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m010_cloud_sync_metadata.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m011_seed_new_combos.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m012_expenses_and_cancellation.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m013_rtdb_resync.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v12-legacy-1';
  final DateTime billedAt = DateTime.utc(2026, 6, 1, 12);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v13_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion12Database(path, orderId: orderId, billedAt: billedAt);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v12 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    expect(const M013RtdbResync().version, 13);
    expect(SqliteDatabase.schemaVersion, 16);
  });

  test('previously synced menu and orders are requeued as pending', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Map<String, Object?> order = (await database.database.query(
      SqliteTables.orders,
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
    )).single;
    expect(order['syncState'], 'pending');
    expect(order['orderNumber'], '20260601-0001');
    expect(order['totalAmountPaise'], 45000);

    final List<Map<String, Object?>> pendingMenu = await database.database.query(
      SqliteTables.menuItems,
      where: 'syncState = ?',
      whereArgs: <Object?>['pending'],
    );
    expect(pendingMenu, isNotEmpty);

    final List<Map<String, Object?>> syncedMenu = await database.database.query(
      SqliteTables.menuItems,
      where: 'syncState = ?',
      whereArgs: <Object?>['synced'],
    );
    expect(syncedMenu, isEmpty);
  });

  test('the pull high-water mark is cleared so RTDB can be fully pulled', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> rows = await database.database.query(
      SqliteTables.syncMetadata,
      where: 'key = ?',
      whereArgs: <Object?>['pull.highWaterMarkMillis'],
    );
    expect(rows, isEmpty);
  });
}

Future<void> _createVersion12Database(
  String path, {
  required String orderId,
  required DateTime billedAt,
}) async {
  final int at = billedAt.millisecondsSinceEpoch;

  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 12,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await const M004ScopedMenuOptions().migrate(db);
        await const M005KotOrderSnapshots().migrate(db);
        await const M006RecipesAndStockDeduction().migrate(db);
        await const M007HeldBills().migrate(db);
        await const M008Refunds().migrate(db);
        await const M009BillTaxAndDiscount().migrate(db);
        await const M010CloudSyncMetadata().migrate(db);
        await const M011SeedNewCombos().migrate(db);
        await const M012ExpensesAndCancellation().migrate(db);

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260601-0001',
          'orderType': 'takeaway',
          'status': 'completed',
          'subtotalPaise': 45000,
          'discountAmountPaise': 0,
          'taxAmountPaise': 0,
          'totalAmountPaise': 45000,
          'taxRateBasisPoints': 0,
          'discountValue': 0,
        });

        await db.update(
          SqliteTables.menuItems,
          <String, Object?>{'syncState': 'synced'},
        );
        await db.update(
          SqliteTables.categories,
          <String, Object?>{'syncState': 'synced'},
        );

        await db.insert(SqliteTables.syncMetadata, <String, Object?>{
          'key': 'pull.highWaterMarkMillis',
          'value': at.toString(),
          'updatedAt': at,
        });
      },
    ),
  );
  await database.close();
}
