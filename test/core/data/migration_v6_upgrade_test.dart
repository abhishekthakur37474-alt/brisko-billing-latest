import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m005_kot_order_snapshots.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement_type.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_unit.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_record.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal already holding real trade upgrades to v6 without losing any
/// of it, and that a stock item written under the old free-text unit is read correctly.
///
/// This is the case no other test can reach: every other database opens straight at the
/// latest version, so the two new tables are created empty and the normalising updates
/// in v6 have nothing to match. Here a genuine v5 database is built with a settled bill,
/// its payment, its kitchen slip and a stock item recorded the old way, and then opened
/// by the current build.
void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v5-legacy-1';
  const String paymentId = 'pay-v5-legacy-1';
  const String kotId = 'kot-v5-legacy-1';
  const String stockItemId = 'inv-v5-legacy-1';
  const String movementId = 'stk-v5-legacy-1';

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v6_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion5Database(
      path,
      orderId: orderId,
      paymentId: paymentId,
      kotId: kotId,
      stockItemId: stockItemId,
      movementId: movementId,
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v5 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    // Held bills (v7), refunds (v8), the bill's own GST rate and discount rule (v9) and
    // the cloud sync bookmarks (v10) all landed after this upgrade path, so the current
    // version has moved well past 6. Opening a v5 database still carries it all the way to
    // the latest.
    expect(SqliteDatabase.schemaVersion, 16);
  });

  test('the recipe and deduction tables are added', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Set<String> recipeColumns = await _columnsOf(
      database,
      SqliteTables.recipeIngredients,
    );
    expect(
      recipeColumns,
      containsAll(<String>[
        'menuItemId',
        'variantId',
        'inventoryItemId',
        'quantityMilli',
      ]),
    );
    // A recipe is configuration, not a bill, so it carries no money at all.
    expect(recipeColumns.any((String name) => name.contains('Paise')), isFalse);

    expect(
      await _columnsOf(database, SqliteTables.orderInventoryDeductions),
      containsAll(<String>[
        'orderId',
        'orderNumberSnapshot',
        'status',
        'attemptCount',
        'movementCount',
        'unconfiguredCount',
        'unconfiguredItems',
        'failureMessage',
      ]),
    );
  });

  test('the existing bill, payment and kitchen slip all survive', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Order? order = (await SqliteOrderRepository(
      database: database,
    ).findOrder(orderId)).valueOrNull;
    expect(order, isNotNull);
    expect(order!.orderNumber, '20260101-0009');
    expect(order.totalAmount.paise, 32000);

    final List<Payment> tendered = (await SqlitePaymentRepository(
      database: database,
    ).loadForOrder(orderId)).valueOrNull!;
    expect(tendered, hasLength(1));
    expect(tendered.single.amount.paise, 32000);

    final KotRecord? slip = (await SqliteKotRepository(
      database: database,
    ).findKot(kotId)).valueOrNull;
    expect(slip, isNotNull);
    expect(slip!.kotNumber, 'K20260101-0004');
  });

  test('the seeded menu survives', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<MenuItem> items = (await SqliteMenuRepository(
      database: database,
    ).loadItems()).valueOrNull!;

    expect(items, isNotEmpty);
    expect(
      items.map((MenuItem item) => item.name),
      contains('Cheese Pizza'),
      reason: 'the seeded menu must not be re-seeded or dropped',
    );
  });

  test('a stock item stored with a free-text unit is read correctly', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final InventoryItem? item = (await SqliteInventoryRepository(
      database: database,
    ).findItem(stockItemId)).valueOrNull;

    expect(item, isNotNull);
    // Written as 'kg' before units were a closed set.
    expect(item!.unit, StockUnit.kilogram);
    expect(item.currentQuantityMilli, 12500);
    expect(item.currentQuantityWithUnit, '12.5 kg');
  });

  test('an existing purchase movement is retokenised as stock in', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<StockMovement> ledger = (await SqliteInventoryRepository(
      database: database,
    ).loadMovements(stockItemId)).valueOrNull!;

    expect(ledger, hasLength(1));
    expect(ledger.single.movementType, StockMovementType.stockIn);
    // The quantity and the reason are untouched by the retokenisation.
    expect(ledger.single.quantityMilli, 12500);
    expect(ledger.single.reason, 'legacy delivery');
  });

  test('foreign keys hold across the whole upgraded database', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> violations = await database.database
        .rawQuery('PRAGMA foreign_key_check');

    expect(violations, isEmpty);
  });

  test(
    'an upgraded database accepts a recipe against the seeded menu',
    () async {
      final SqliteDatabase database = await TestDatabase.openOnDisk(path);
      addTearDown(database.close);

      final MenuItem dish = (await SqliteMenuRepository(
        database: database,
      ).loadItems()).valueOrNull!.first;

      final bool added =
          (await SqliteRecipeRepository(database: database).addIngredient(
            scope: RecipeScope.product(dish.id),
            inventoryItemId: stockItemId,
            quantityMilli: 150,
          )).isOk;

      expect(added, isTrue);
    },
  );

  test('a fresh database and an upgraded one agree on the schema', () async {
    // The guarantee the migration runner exists for: a new terminal and an upgraded
    // one end up with the same tables.
    final SqliteDatabase upgraded = await TestDatabase.openOnDisk(path);
    addTearDown(upgraded.close);
    final SqliteDatabase fresh = await TestDatabase.openInMemory();
    addTearDown(fresh.close);

    expect(await _tablesOf(upgraded), await _tablesOf(fresh));
    expect(
      await _columnsOf(upgraded, SqliteTables.recipeIngredients),
      await _columnsOf(fresh, SqliteTables.recipeIngredients),
    );
    expect(
      await _columnsOf(upgraded, SqliteTables.orderInventoryDeductions),
      await _columnsOf(fresh, SqliteTables.orderInventoryDeductions),
    );
  });
}

Future<Set<String>> _columnsOf(SqliteDatabase database, String table) async {
  final List<Map<String, Object?>> rows = await database.database.rawQuery(
    'PRAGMA table_info($table)',
  );
  return rows.map((Map<String, Object?> row) => row['name']! as String).toSet();
}

Future<Set<String>> _tablesOf(SqliteDatabase database) async {
  final List<Map<String, Object?>> rows = await database.database.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((Map<String, Object?> row) => row['name']! as String).toSet();
}

/// Builds a database in exactly the state migration v5 left it in.
///
/// The five shipped migrations are replayed, then a bill, its payment, its kitchen slip
/// and a stock item are inserted using only what v5 had. The stock rows are written by
/// hand rather than through the models on purpose: the unit was free text then and the
/// movement type was `purchase`, neither of which the current models would produce.
Future<void> _createVersion5Database(
  String path, {
  required String orderId,
  required String paymentId,
  required String kotId,
  required String stockItemId,
  required String movementId,
}) async {
  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 5,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await const M004ScopedMenuOptions().migrate(db);
        await const M005KotOrderSnapshots().migrate(db);

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260101-0009',
          'orderType': 'takeaway',
          'status': 'completed',
          'subtotalPaise': 32000,
          'totalAmountPaise': 32000,
        });

        await db.insert(SqliteTables.payments, <String, Object?>{
          'id': paymentId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'paymentMethod': 'cash',
          'amountPaise': 32000,
          'status': 'completed',
        });

        await db.insert(SqliteTables.kotRecords, <String, Object?>{
          'id': kotId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'kotNumber': 'K20260101-0004',
          'status': 'pending',
          'orderNumber': '20260101-0009',
          'orderType': 'takeaway',
        });

        // The old shape: a unit as a symbol, and a movement type of 'purchase'.
        await db.insert(SqliteTables.inventoryItems, <String, Object?>{
          'id': stockItemId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'name': 'Legacy Stock Item',
          'unit': 'kg',
          'currentQuantityMilli': 12500,
          'minimumQuantityMilli': 2000,
          'isActive': 1,
        });

        await db.insert(SqliteTables.stockMovements, <String, Object?>{
          'id': movementId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'inventoryItemId': stockItemId,
          'movementType': 'purchase',
          'quantityMilli': 12500,
          'reason': 'legacy delivery',
        });
      },
    ),
  );
  await database.close();
}
