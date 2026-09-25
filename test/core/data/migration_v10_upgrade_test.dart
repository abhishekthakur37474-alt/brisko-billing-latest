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
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal trading on v9 upgrades to v10 — the cloud sync
/// bookmarks — without touching a single bill.
///
/// The migration only adds a `sync_metadata` table, so the guarantee is entirely
/// about what it does *not* do: it must not rewrite, drop or reseed anything.
void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v9-legacy-1';
  final DateTime billedAt = DateTime.utc(2026, 5, 10, 9, 15);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v10_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion9Database(path, orderId: orderId, billedAt: billedAt);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Set<String>> tablesOf(SqliteDatabase database) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();
  }

  test('a v9 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    expect(const M010CloudSyncMetadata().version, 10);
    expect(SqliteDatabase.schemaVersion, 16);
  });

  test('the sync_metadata table is created', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await tablesOf(database), contains(SqliteTables.syncMetadata));

    // It is writable and reads back what was written.
    await database.database.insert(SqliteTables.syncMetadata, <String, Object?>{
      'key': 'probe',
      'value': '42',
      'updatedAt': 1,
    });
    final Map<String, Object?> row = (await database.database.query(
      SqliteTables.syncMetadata,
      where: 'key = ?',
      whereArgs: <Object?>['probe'],
    )).single;
    expect(row['value'], '42');
  });

  test('the legacy bill is not rewritten by the upgrade', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Order order = (await SqliteOrderRepository(
      database: database,
    ).findOrder(orderId)).valueOrNull!;

    expect(order.orderNumber, '20260510-0001');
    expect(order.status, OrderStatus.completed);
    expect(order.totalAmount, Money.parse('450.00'));

    final Map<String, Object?> row = (await database.database.query(
      SqliteTables.orders,
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
    )).single;
    // Amounts and timestamps are untouched. v13 requeues previously synced rows
    // so they upload to Realtime Database.
    expect(row['createdAt'], billedAt.millisecondsSinceEpoch);
    expect(row['updatedAt'], billedAt.millisecondsSinceEpoch);
    expect(row['syncState'], 'pending');
  });

  test('foreign keys hold across the upgraded database', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> violations = await database.database
        .rawQuery('PRAGMA foreign_key_check');
    expect(violations, isEmpty);
  });

  test('a fresh database and an upgraded one agree on the tables', () async {
    final SqliteDatabase upgraded = await TestDatabase.openOnDisk(path);
    addTearDown(upgraded.close);
    final SqliteDatabase fresh = await TestDatabase.openInMemory();
    addTearDown(fresh.close);

    expect(await tablesOf(upgraded), await tablesOf(fresh));
  });
}

/// Builds a database in exactly the state migration v9 left it in: the nine
/// shipped migrations replayed, plus one settled bill written by hand.
Future<void> _createVersion9Database(
  String path, {
  required String orderId,
  required DateTime billedAt,
}) async {
  final int at = billedAt.millisecondsSinceEpoch;

  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 9,
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

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260510-0001',
          'orderType': 'takeaway',
          'status': 'completed',
          'subtotalPaise': 45000,
          'discountAmountPaise': 0,
          'taxAmountPaise': 0,
          'totalAmountPaise': 45000,
          'taxRateBasisPoints': 0,
          'discountValue': 0,
        });
      },
    ),
  );
  await database.close();
}
