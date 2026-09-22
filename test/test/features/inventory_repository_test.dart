import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement_type.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_quantity.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_unit.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

/// Stock items, the ledger, and the two invariants that hold them together: a balance
/// never moves without a movement, and stock never goes negative.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteInventoryRepository inventory;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    inventory = SqliteInventoryRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// The stored balance, read fresh.
  Future<int> balanceOf(String id) async =>
      (await inventory.findItem(id)).valueOrNull!.currentQuantityMilli;

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  group('quantity representation', () {
    test('parses and formats thousandths without floating point', () {
      expect(StockQuantity.parse('10'), 10000);
      expect(StockQuantity.parse('2.5'), 2500);
      expect(StockQuantity.parse('0.125'), 125);
      expect(StockQuantity.format(2500), '2.5');
      expect(StockQuantity.format(10000), '10');
      expect(StockQuantity.format(125), '0.125');
    });

    test('the model exposes the same conversion', () {
      // One representation across the feature, so a recipe quantity and a balance are
      // the same kind of number.
      expect(InventoryItem.parseQuantity('2.5'), StockQuantity.parse('2.5'));
      expect(InventoryItem.formatQuantity(2500), StockQuantity.format(2500));
    });

    test('rejects more precision than thousandths', () {
      expect(() => StockQuantity.parse('1.0001'), throwsFormatException);
      expect(StockQuantity.tryParse('1.0001'), isNull);
      expect(StockQuantity.tryParse('not a number'), isNull);
    });

    test('scaling a per-unit amount to a sold quantity is exact', () {
      // 100 g of cheese, three pizzas.
      expect(StockQuantity.forQuantity(100, 3), 300);
      expect(StockQuantity.forQuantity(StockQuantity.parse('0.15'), 7), 1050);
    });
  });

  group('units', () {
    test('every unit the outlet needs is offered', () {
      expect(StockUnit.values.map((StockUnit u) => u.name), <String>[
        'gram',
        'kilogram',
        'millilitre',
        'litre',
        'piece',
      ]);
    });

    test('a unit is read by name or by its short code', () {
      expect(StockUnit.tryParse('kilogram'), StockUnit.kilogram);
      expect(StockUnit.tryParse('kg'), StockUnit.kilogram);
      expect(StockUnit.tryParse('KG'), StockUnit.kilogram);
      expect(StockUnit.tryParse('furlong'), isNull);
    });

    test('an unreadable stored unit degrades rather than failing the read', () {
      // A row written by a newer build must not make the whole list unopenable.
      expect(StockUnit.read('furlong'), StockUnit.fallback);
    });
  });

  group('creating an item', () {
    test('an item can be saved and retrieved', () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Cheese',
        currentQuantity: '10',
        minimumQuantity: '2',
      );
      expect((await inventory.saveItem(item)).isOk, isTrue);

      final InventoryItem? loaded = (await inventory.findItem(item.id))
          .valueOrNull;

      expect(loaded, isNotNull);
      expect(loaded!.name, 'Test Cheese');
      expect(loaded.unit, StockUnit.kilogram);
      expect(loaded.currentQuantityMilli, 10000);
      expect(loaded.currentQuantityDisplay, '10');
      expect(loaded.currentQuantityWithUnit, '10 kg');
    });

    test('a blank name is rejected', () async {
      final Result<void> result = await inventory.saveItem(
        Fixtures.inventoryItem(name: '   '),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('needs a name'));
      expect(await rowCount('inventory_items'), 0);
    });

    test('a negative low stock threshold is rejected', () async {
      final InventoryItem item = Fixtures.inventoryItem();
      final Result<void> result = await inventory.saveItem(
        item.copyWith(minimumQuantityMilli: -1000),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('cannot be negative'));
    });

    test('a negative opening balance is rejected', () async {
      final Result<void> result = await inventory.saveItem(
        Fixtures.inventoryItem().copyWith(currentQuantityMilli: -1),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('editing an item cannot move its balance', () async {
      // The invariant: a balance changes through the ledger or not at all. Without
      // this, an edit would be an untraceable stock movement.
      final InventoryItem item = Fixtures.inventoryItem(currentQuantity: '10');
      await inventory.saveItem(item);

      final Result<void> result = await inventory.saveItem(
        item.copyWith(currentQuantityMilli: 99000),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('stock in'));
      expect(await balanceOf(item.id), 10000);
    });

    test('editing the name, unit and threshold is allowed', () async {
      final InventoryItem item = Fixtures.inventoryItem(currentQuantity: '10');
      await inventory.saveItem(item);

      final Result<void> result = await inventory.saveItem(
        item.copyWith(
          name: 'Test Renamed',
          unit: StockUnit.gram,
          minimumQuantityMilli: StockQuantity.parse('4'),
        ),
      );

      expect(result.isOk, isTrue);
      final InventoryItem updated = (await inventory.findItem(item.id))
          .valueOrNull!;
      expect(updated.name, 'Test Renamed');
      expect(updated.unit, StockUnit.gram);
      expect(updated.minimumQuantityMilli, 4000);
      expect(updated.currentQuantityMilli, 10000);
    });
  });

  group('manual stock operations', () {
    late InventoryItem item;

    setUp(() async {
      item = Fixtures.inventoryItem(
        currentQuantity: '10',
        minimumQuantity: '2',
      );
      await inventory.saveItem(item);
    });

    test('stock in increases the balance and is recorded', () async {
      final StockMovement movement = (await inventory.stockIn(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('5.5'),
        reason: 'test delivery',
      )).valueOrNull!;

      expect(movement.movementType, StockMovementType.stockIn);
      expect(movement.signedQuantityMilli, 5500);
      expect(movement.signedQuantityDisplay, '+5.5');
      expect(await balanceOf(item.id), 15500);

      final List<StockMovement> ledger = (await inventory.loadMovements(
        item.id,
      )).valueOrNull!;
      expect(ledger, hasLength(1));
      expect(ledger.single.reason, 'test delivery');
    });

    test('wastage decreases the balance', () async {
      final StockMovement movement = (await inventory.recordWastage(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('1.25'),
        reason: 'spoiled',
      )).valueOrNull!;

      expect(movement.movementType, StockMovementType.wastage);
      expect(movement.signedQuantityDisplay, '-1.25');
      expect(await balanceOf(item.id), 8750);
    });

    test('stock out decreases the balance', () async {
      await inventory.stockOut(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('3'),
        reason: 'sent to an event',
      );

      expect(await balanceOf(item.id), 7000);
    });

    test('an adjustment adds or removes by its own sign', () async {
      await inventory.adjust(
        inventoryItemId: item.id,
        quantityMilli: -2000,
        reason: 'monthly count',
      );
      expect(await balanceOf(item.id), 8000);

      await inventory.adjust(inventoryItemId: item.id, quantityMilli: 500);
      expect(await balanceOf(item.id), 8500);
    });

    test('the balance stays exact over many fractional movements', () async {
      for (int i = 0; i < 100; i++) {
        await inventory.recordWastage(
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('0.001'),
        );
      }

      // 10 kg less 100 thousandths, with no drift.
      expect(await balanceOf(item.id), 10000 - 100);
    });

    test('a movement of zero is rejected', () async {
      final Result<StockMovement> result = await inventory.adjust(
        inventoryItemId: item.id,
        quantityMilli: 0,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await rowCount('stock_movements'), 0);
    });

    test('a negative quantity on a directional movement is rejected', () async {
      // "-2 kg of wastage" reads as stock arriving. The type carries the direction.
      final Result<StockMovement> result = await inventory.recordWastage(
        inventoryItemId: item.id,
        quantityMilli: -2000,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await balanceOf(item.id), 10000);
    });

    test('the ledger is returned newest first', () async {
      await inventory.stockIn(
        inventoryItemId: item.id,
        quantityMilli: 1000,
        reason: 'first',
      );
      await inventory.stockIn(
        inventoryItemId: item.id,
        quantityMilli: 1000,
        reason: 'second',
      );

      final List<StockMovement> ledger = (await inventory.loadMovements(
        item.id,
      )).valueOrNull!;
      expect(ledger, hasLength(2));
      expect(ledger.first.reason, 'second');
    });
  });

  group('stock never goes negative', () {
    late InventoryItem item;

    setUp(() async {
      item = Fixtures.inventoryItem(name: 'Test Flour', currentQuantity: '2');
      await inventory.saveItem(item);
    });

    test('wastage cannot exceed the balance', () async {
      final Result<StockMovement> result = await inventory.recordWastage(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('2.001'),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('Not enough Test Flour'));
      // The figures are named, so the operator knows what to go and count.
      expect(result.failureOrNull!.message, contains('2.001 kg needed'));
      expect(result.failureOrNull!.message, contains('2 kg in stock'));
    });

    test('a stock out cannot exceed the balance', () async {
      final Result<StockMovement> result = await inventory.stockOut(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('3'),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('an adjustment cannot produce a negative balance', () async {
      final Result<StockMovement> result = await inventory.adjust(
        inventoryItemId: item.id,
        quantityMilli: -StockQuantity.parse('2.5'),
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test(
      'a refused movement leaves the balance and the ledger unchanged',
      () async {
        await inventory.recordWastage(
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('99'),
        );

        // Atomicity: neither half of the pair survives.
        expect(await balanceOf(item.id), 2000);
        expect(await rowCount('stock_movements'), 0);
      },
    );

    test('emptying the shelf exactly is allowed', () async {
      // Zero is a real balance. Only below zero is impossible.
      expect(
        (await inventory.recordWastage(
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('2'),
        )).isOk,
        isTrue,
      );
      expect(await balanceOf(item.id), 0);
    });
  });

  group('atomicity', () {
    test('a movement against a missing item records nothing', () async {
      final Result<StockMovement> result = await inventory.stockIn(
        inventoryItemId: 'inv-does-not-exist',
        quantityMilli: 1000,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(
        await rowCount('stock_movements'),
        0,
        reason: 'the transaction must have rolled back',
      );
    });

    test('a movement against a deleted item records nothing', () async {
      final InventoryItem item = Fixtures.inventoryItem();
      await inventory.saveItem(item);
      await inventory.deleteItem(item.id);

      final Result<StockMovement> result = await inventory.stockIn(
        inventoryItemId: item.id,
        quantityMilli: 1000,
      );

      expect(result.isErr, isTrue);
      expect(await rowCount('stock_movements'), 0);
    });
  });

  group('low stock', () {
    Future<List<String>> reportedLow() async {
      final List<InventoryItem> items =
          (await inventory.loadLowStockItems()).valueOrNull!;
      return items.map((InventoryItem item) => item.name).toList();
    }

    test('a balance above the threshold is not low', () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Above',
        currentQuantity: '2.001',
        minimumQuantity: '2',
      );
      await inventory.saveItem(item);

      expect(item.isLow, isFalse);
      expect(await reportedLow(), isEmpty);
    });

    test('a balance equal to the threshold is low', () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Equal',
        currentQuantity: '2',
        minimumQuantity: '2',
      );
      await inventory.saveItem(item);

      expect(item.isLow, isTrue);
      expect(await reportedLow(), <String>['Test Equal']);
    });

    test('a balance below the threshold is low', () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Below',
        currentQuantity: '1.999',
        minimumQuantity: '2',
      );
      await inventory.saveItem(item);

      expect(item.isLow, isTrue);
      expect(await reportedLow(), <String>['Test Below']);
    });

    test('an item with no threshold is never reported as low', () async {
      // A minimum of zero means "not monitored", not "always low".
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Unmonitored',
        currentQuantity: '0',
        minimumQuantity: '0',
      );
      await inventory.saveItem(item);

      expect(item.isLow, isFalse);
      expect(item.isMonitored, isFalse);
      expect(await reportedLow(), isEmpty);
    });

    test('selling stock down crosses the threshold', () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: 'Test Crossing',
        currentQuantity: '5',
        minimumQuantity: '2',
      );
      await inventory.saveItem(item);
      expect(await reportedLow(), isEmpty);

      await inventory.recordWastage(
        inventoryItemId: item.id,
        quantityMilli: StockQuantity.parse('3'),
      );

      expect(await reportedLow(), <String>['Test Crossing']);
    });
  });

  group('deleting an item', () {
    test('a deleted item is hidden but its row remains', () async {
      final InventoryItem item = Fixtures.inventoryItem();
      await inventory.saveItem(item);

      expect((await inventory.deleteItem(item.id)).isOk, isTrue);

      expect((await inventory.findItem(item.id)).valueOrNull, isNull);
      expect((await inventory.loadItems()).valueOrNull, isEmpty);

      final List<Map<String, Object?>> raw = await database.database.query(
        'inventory_items',
        where: 'id = ?',
        whereArgs: <Object?>[item.id],
      );
      expect(raw.single['isDeleted'], 1);
    });

    test('an item a recipe still uses cannot be deleted', () async {
      // Allowing it would turn every later sale of that dish into a failed
      // deduction, met one bill at a time instead of here, once.
      final SqliteMenuRepository menu = SqliteMenuRepository(
        database: database,
      );
      final SqliteRecipeRepository recipes = SqliteRecipeRepository(
        database: database,
      );
      final InventoryItem item = Fixtures.inventoryItem(name: 'Test Used');
      await inventory.saveItem(item);

      final MenuItem dish = (await menu.loadItems()).valueOrNull!.first;
      await recipes.addIngredient(
        scope: RecipeScope.product(dish.id),
        inventoryItemId: item.id,
        quantityMilli: 100,
      );

      final Result<void> result = await inventory.deleteItem(item.id);

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('recipe still uses'));
      expect((await inventory.findItem(item.id)).valueOrNull, isNotNull);
    });
  });

  group('offline', () {
    test('stock survives closing and reopening the database', () async {
      // Proves the feature is genuinely on local storage, with no network anywhere in
      // the path. An in-memory database cannot demonstrate this.
      final Directory directory = await Directory.systemTemp.createTemp(
        'brisko_stock_offline',
      );
      addTearDown(() => directory.delete(recursive: true));
      final String path = p.join(directory.path, 'stock.db');

      final String itemId = EntityId.generate(prefix: 'inv');
      final SqliteDatabase first = await TestDatabase.openOnDisk(path);
      final SqliteInventoryRepository writer = SqliteInventoryRepository(
        database: first,
      );
      await writer.saveItem(
        Fixtures.inventoryItem(
          id: itemId,
          name: 'Test Persisted',
          currentQuantity: '0',
          minimumQuantity: '1',
        ),
      );
      await writer.stockIn(
        inventoryItemId: itemId,
        quantityMilli: StockQuantity.parse('7.25'),
        reason: 'opening stock',
      );
      await first.close();

      final SqliteDatabase second = await TestDatabase.openOnDisk(path);
      addTearDown(second.close);
      final SqliteInventoryRepository reader = SqliteInventoryRepository(
        database: second,
      );

      final InventoryItem reloaded = (await reader.findItem(itemId))
          .valueOrNull!;
      expect(reloaded.name, 'Test Persisted');
      expect(reloaded.currentQuantityMilli, 7250);

      final List<StockMovement> ledger = (await reader.loadMovements(itemId))
          .valueOrNull!;
      expect(ledger, hasLength(1));
      expect(ledger.single.reason, 'opening stock');
      expect(ledger.single.movementType, StockMovementType.stockIn);
    });
  });
}
