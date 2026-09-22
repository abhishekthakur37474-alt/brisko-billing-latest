import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/inventory_item.dart';
import '../../domain/models/stock_movement.dart';
import '../../domain/models/stock_movement_type.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../stock_ledger.dart';

/// SQLite implementation of [InventoryRepository].
class SqliteInventoryRepository implements InventoryRepository {
  SqliteInventoryRepository({required SqliteDatabase database})
    : _database = database,
      _items = SqliteLocalStore<InventoryItem>(
        database: database,
        table: SqliteTables.inventoryItems,
        fromRow: InventoryItem.fromRow,
        orderBy: 'name ASC',
      );

  final SqliteDatabase _database;
  final SqliteLocalStore<InventoryItem> _items;

  Database get _db => _database.database;

  @override
  Future<Result<List<InventoryItem>>> loadItems() {
    return SqliteErrorMapper.guard<List<InventoryItem>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.inventoryItems,
        where: 'isDeleted = 0 AND isActive = 1',
        orderBy: 'name ASC',
      );
      return rows.map(InventoryItem.fromRow).toList(growable: false);
    }, context: 'load the stock items');
  }

  @override
  Stream<List<InventoryItem>> watchItems() => _items.watchAll();

  @override
  Future<Result<InventoryItem?>> findItem(String id) => _items.findById(id);

  @override
  Future<Result<List<InventoryItem>>> loadLowStockItems() {
    return SqliteErrorMapper.guard<List<InventoryItem>>(() async {
      // A minimum of zero means the item is not monitored, so it is excluded
      // rather than perpetually reported as low.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.inventoryItems,
        where:
            'isDeleted = 0 AND isActive = 1 '
            'AND minimumQuantityMilli > 0 '
            'AND currentQuantityMilli <= minimumQuantityMilli',
        orderBy: 'name ASC',
      );
      return rows.map(InventoryItem.fromRow).toList(growable: false);
    }, context: 'load low stock items');
  }

  @override
  Future<Result<void>> saveItem(InventoryItem item) {
    return SqliteErrorMapper.guard<void>(() async {
      if (item.name.trim().isEmpty) {
        throw ArgumentError.value(
          item.name,
          'name',
          'A stock item needs a name',
        );
      }
      if (item.minimumQuantityMilli < 0) {
        throw ArgumentError.value(
          item.minimumQuantityMilli,
          'minimumQuantityMilli',
          'A low stock threshold cannot be negative',
        );
      }
      if (item.currentQuantityMilli < 0) {
        throw ArgumentError.value(
          item.currentQuantityMilli,
          'currentQuantityMilli',
          'A stock balance cannot be negative',
        );
      }

      // The balance is the ledger's, not the caller's. An edit that carried a
      // different figure would move stock with nothing to explain it, so it is
      // refused here rather than quietly applied. New items are unaffected: there is
      // no stored balance to contradict.
      final List<Map<String, Object?>> existing = await _db.query(
        SqliteTables.inventoryItems,
        columns: <String>['currentQuantityMilli', 'name'],
        where: '${SyncColumns.id} = ?',
        whereArgs: <Object?>[item.id],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        final int stored = existing.first['currentQuantityMilli']! as int;
        if (stored != item.currentQuantityMilli) {
          throw ArgumentError.value(
            item.currentQuantityMilli,
            'currentQuantityMilli',
            'The balance of ${existing.first['name']} is changed by recording '
                'stock in, wastage or an adjustment, not by editing the item',
          );
        }
      }

      await _items.save(item);
    }, context: 'save the stock item');
  }

  @override
  Future<Result<StockMovement>> stockIn({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  }) {
    return recordMovement(
      inventoryItemId: inventoryItemId,
      type: StockMovementType.stockIn,
      quantityMilli: quantityMilli,
      reason: reason,
    );
  }

  @override
  Future<Result<StockMovement>> adjust({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  }) {
    return recordMovement(
      inventoryItemId: inventoryItemId,
      type: StockMovementType.adjustment,
      quantityMilli: quantityMilli,
      reason: reason,
    );
  }

  @override
  Future<Result<StockMovement>> recordWastage({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  }) {
    return recordMovement(
      inventoryItemId: inventoryItemId,
      type: StockMovementType.wastage,
      quantityMilli: quantityMilli,
      reason: reason,
    );
  }

  @override
  Future<Result<StockMovement>> stockOut({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  }) {
    return recordMovement(
      inventoryItemId: inventoryItemId,
      type: StockMovementType.stockOut,
      quantityMilli: quantityMilli,
      reason: reason,
    );
  }

  @override
  Future<Result<StockMovement>> recordMovement({
    required String inventoryItemId,
    required StockMovementType type,
    required int quantityMilli,
    String? reason,
    String? referenceId,
  }) {
    return SqliteErrorMapper.guard<StockMovement>(() async {
      if (quantityMilli == 0) {
        throw ArgumentError.value(
          quantityMilli,
          'quantityMilli',
          'A movement of zero has no effect',
        );
      }
      if (type.requiresPositiveQuantity && quantityMilli < 0) {
        // The type already carries the direction. Accepting a negative here would
        // mean "-2 kg of wastage", which reads as stock arriving.
        throw ArgumentError.value(
          quantityMilli,
          'quantityMilli',
          'A ${type.label.toLowerCase()} quantity has to be positive',
        );
      }

      final DateTime now = DateTime.now().toUtc();
      final StockMovement movement = StockMovement(
        id: EntityId.generate(prefix: 'stk'),
        inventoryItemId: inventoryItemId,
        movementType: type,
        quantityMilli: quantityMilli,
        reason: reason,
        referenceId: referenceId,
        createdAt: now,
        updatedAt: now,
      );

      await _db.transaction(
        (Transaction txn) =>
            StockLedger.record(txn, movement: movement, at: now),
      );

      // After the commit, never inside it: a watcher that read the tables mid
      // transaction would see a balance that might still roll back.
      _database.notifyTablesChanged(StockLedger.tables);

      return movement;
    }, context: 'record the stock movement');
  }

  @override
  Future<Result<List<StockMovement>>> loadMovements(
    String inventoryItemId, {
    int limit = 100,
  }) {
    return SqliteErrorMapper.guard<List<StockMovement>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.stockMovements,
        where: 'inventoryItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[inventoryItemId],
        orderBy: 'createdAt DESC, rowid DESC',
        limit: limit,
      );
      return rows.map(StockMovement.fromRow).toList(growable: false);
    }, context: 'load the stock ledger');
  }

  @override
  Future<Result<void>> deleteItem(String id) async {
    // Queried here rather than through RecipeRepository so this repository owns one
    // connection and no repository depends on another. Both tables belong to the
    // inventory feature's data layer, so the SQL is still in one place.
    final Result<bool> inUse = await SqliteErrorMapper.guard<bool>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.recipeIngredients,
        columns: <String>[SyncColumns.id],
        where: 'inventoryItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return rows.isNotEmpty;
    }, context: 'check whether a recipe uses this stock item');

    return switch (inUse) {
      Err<bool>(:final AppFailure failure) => Err<void>(failure),
      Ok<bool>(value: true) => const Err<void>(
        ValidationFailure(
          'A recipe still uses this stock item. Remove it from the recipes '
          'first.',
        ),
      ),
      Ok<bool>() => _items.softDelete(id),
    };
  }
}
