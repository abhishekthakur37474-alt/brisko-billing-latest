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
import 'package:brisko_billing/core/data/local/sqlite/migrations/m014_order_customer_name.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m015_spec_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m016_order_customer_address.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v15-legacy-1';
  final DateTime billedAt = DateTime.utc(2026, 9, 1, 12);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v16_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion15Database(path, orderId: orderId, billedAt: billedAt);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v15 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    expect(const M016OrderCustomerAddress().version, 16);
    expect(SqliteDatabase.schemaVersion, 16);
  });

  test('the customerAddress column is added to the orders table', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> columns = await database.database.rawQuery(
      'PRAGMA table_info(${SqliteTables.orders})',
    );
    final Set<String> names = columns
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();
    expect(names, contains('customerAddress'));
  });

  test('a bill settled before the column reads back with no address', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Order order = (await SqliteOrderRepository(
      database: database,
    ).findOrder(orderId)).valueOrNull!;

    expect(order.orderNumber, '20260901-0001');
    expect(order.customerName, 'Ravi');
    expect(order.customerAddress, isNull);
    expect(order.totalAmount.paise, 45000);
  });
}

Future<void> _createVersion15Database(
  String path, {
  required String orderId,
  required DateTime billedAt,
}) async {
  final int at = billedAt.millisecondsSinceEpoch;

  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 15,
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
        await const M013RtdbResync().migrate(db);
        await const M014OrderCustomerName().migrate(db);
        await const M015SpecMenu().migrate(db);

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'pending',
          'orderNumber': '20260901-0001',
          'orderType': 'takeaway',
          'status': 'completed',
          'customerName': 'Ravi',
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
