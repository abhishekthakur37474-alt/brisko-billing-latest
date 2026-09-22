import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/recipe.dart';
import '../../domain/models/recipe_ingredient.dart';
import '../../domain/models/recipe_scope.dart';
import '../../domain/repositories/recipe_repository.dart';

/// SQLite implementation of [RecipeRepository].
///
/// Every rule the schema cannot express is checked here and reported as a
/// [ValidationFailure]: a non-positive quantity, a stock item that has been deleted, a
/// dish that does not exist, a duplicate ingredient. The partial unique indexes on
/// `recipe_ingredients` remain as a backstop, but they are reached only by a race,
/// because a constraint error would surface as "that record already exists" rather
/// than naming what the operator did.
class SqliteRecipeRepository implements RecipeRepository {
  SqliteRecipeRepository({required this._database});

  final SqliteDatabase _database;

  Database get _db => _database.database;

  @override
  Future<Result<Recipe>> loadRecipe(RecipeScope scope) {
    return SqliteErrorMapper.guard<Recipe>(
      () async =>
          Recipe(scope: scope, ingredients: await _linesFor(_db, scope)),
      context: 'load the recipe',
    );
  }

  @override
  Future<Result<Recipe>> resolveRecipe(RecipeScope scope) {
    return SqliteErrorMapper.guard<Recipe>(() async {
      final List<RecipeIngredient> own = await _linesFor(_db, scope);
      if (own.isNotEmpty) {
        return Recipe(scope: scope, ingredients: own);
      }

      // The size has nothing of its own, so the product-level recipe applies. This
      // is the same resolution the deduction performs, kept identical on purpose:
      // the recipe screen must be able to tell the operator what a sale will
      // actually consume.
      final RecipeScope? fallback = scope.fallback;
      if (fallback == null) {
        return Recipe.empty(scope);
      }
      return Recipe(
        scope: fallback,
        ingredients: await _linesFor(_db, fallback),
      );
    }, context: 'resolve the recipe');
  }

  @override
  Future<Result<List<RecipeIngredient>>> loadIngredientsForMenuItem(
    String menuItemId,
  ) {
    return SqliteErrorMapper.guard<List<RecipeIngredient>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.recipeIngredients,
        where: 'menuItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[menuItemId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(RecipeIngredient.fromRow).toList(growable: false);
    }, context: 'load the recipes for this item');
  }

  @override
  Future<Result<Set<String>>> loadConfiguredMenuItemIds() {
    return SqliteErrorMapper.guard<Set<String>>(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        'SELECT DISTINCT menuItemId FROM ${SqliteTables.recipeIngredients} '
        'WHERE isDeleted = 0',
      );
      return rows
          .map((Map<String, Object?> row) => row['menuItemId']! as String)
          .toSet();
    }, context: 'load which items have a recipe');
  }

  @override
  Future<Result<RecipeIngredient>> addIngredient({
    required RecipeScope scope,
    required String inventoryItemId,
    required int quantityMilli,
  }) {
    return SqliteErrorMapper.guard<RecipeIngredient>(() async {
      _rejectQuantity(quantityMilli);

      final DateTime now = DateTime.now().toUtc();
      late RecipeIngredient written;

      // One transaction covering the checks and the insert. Checking outside it
      // would leave a window in which the stock item is deleted between being
      // verified and being referenced.
      await _db.transaction((Transaction txn) async {
        await _requireMenuItem(txn, scope.menuItemId);
        if (scope.variantId != null) {
          await _requireVariant(txn, scope);
        }
        await _requireInventoryItem(txn, inventoryItemId);
        await _rejectDuplicate(txn, scope, inventoryItemId);

        written = RecipeIngredient(
          id: EntityId.generate(prefix: 'rcp'),
          menuItemId: scope.menuItemId,
          variantId: scope.variantId,
          inventoryItemId: inventoryItemId,
          quantityMilli: quantityMilli,
          createdAt: now,
          updatedAt: now,
        );

        await SqliteUpsert.run(
          txn,
          SqliteTables.recipeIngredients,
          written.toMap(),
        );
      });

      _database.notifyTableChanged(SqliteTables.recipeIngredients);
      return written;
    }, context: 'add the ingredient');
  }

  @override
  Future<Result<void>> updateIngredientQuantity({
    required String ingredientId,
    required int quantityMilli,
  }) {
    return SqliteErrorMapper.guard<void>(() async {
      _rejectQuantity(quantityMilli);

      final int updated = await _db.update(
        SqliteTables.recipeIngredients,
        <String, Object?>{
          'quantityMilli': quantityMilli,
          SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          SyncColumns.syncState: SyncState.pending.name,
        },
        where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[ingredientId],
      );

      if (updated == 0) {
        throw ArgumentError.value(
          ingredientId,
          'ingredientId',
          'That ingredient is no longer part of this recipe',
        );
      }

      _database.notifyTableChanged(SqliteTables.recipeIngredients);
    }, context: 'change the ingredient quantity');
  }

  @override
  Future<Result<void>> removeIngredient(String ingredientId) {
    return SqliteErrorMapper.guard<void>(() async {
      final int updated = await _db.update(
        SqliteTables.recipeIngredients,
        <String, Object?>{
          SyncColumns.isDeleted: 1,
          SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          // The removal is itself a change no backend has seen.
          SyncColumns.syncState: SyncState.pending.name,
        },
        where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[ingredientId],
      );

      if (updated == 0) {
        return;
      }
      _database.notifyTableChanged(SqliteTables.recipeIngredients);
    }, context: 'remove the ingredient');
  }

  @override
  Future<Result<bool>> isInventoryItemInUse(String inventoryItemId) {
    return SqliteErrorMapper.guard<bool>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.recipeIngredients,
        columns: <String>[SyncColumns.id],
        where: 'inventoryItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[inventoryItemId],
        limit: 1,
      );
      return rows.isNotEmpty;
    }, context: 'check whether a recipe uses this stock item');
  }

  // --------------------------------------------------------------- internals ---

  /// The live ingredient lines for exactly [scope].
  ///
  /// `variantId IS NULL` is spelled out rather than compared with `= ?`, because in
  /// SQL a comparison against NULL is never true, so a product-level recipe would
  /// silently return nothing.
  static Future<List<RecipeIngredient>> _linesFor(
    DatabaseExecutor db,
    RecipeScope scope,
  ) async {
    final String? variantId = scope.variantId;
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.recipeIngredients,
      where: variantId == null
          ? 'menuItemId = ? AND variantId IS NULL AND isDeleted = 0'
          : 'menuItemId = ? AND variantId = ? AND isDeleted = 0',
      whereArgs: variantId == null
          ? <Object?>[scope.menuItemId]
          : <Object?>[scope.menuItemId, variantId],
      orderBy: 'createdAt ASC, rowid ASC',
    );
    return rows.map(RecipeIngredient.fromRow).toList(growable: false);
  }

  /// Refuses a quantity that would make the line meaningless.
  ///
  /// Thrown rather than returned because it runs inside [SqliteErrorMapper.guard],
  /// which turns an [ArgumentError] into a `ValidationFailure`. That gives one exit
  /// path for a bad quantity and a locked database alike.
  static void _rejectQuantity(int quantityMilli) {
    if (quantityMilli <= 0) {
      throw ArgumentError.value(
        quantityMilli,
        'quantityMilli',
        'A recipe has to use more than nothing of an ingredient',
      );
    }
  }

  static Future<void> _requireMenuItem(
    DatabaseExecutor db,
    String menuItemId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.menuItems,
      columns: <String>[SyncColumns.id],
      where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[menuItemId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        menuItemId,
        'menuItemId',
        'That menu item no longer exists',
      );
    }
  }

  /// Refuses a size that does not exist, or belongs to a different product.
  ///
  /// The second half matters: without it a recipe could be scoped to a Medium that
  /// belongs to another pizza, and a sale of either dish would then resolve the wrong
  /// ingredients.
  static Future<void> _requireVariant(
    DatabaseExecutor db,
    RecipeScope scope,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.menuItemVariants,
      columns: <String>[SyncColumns.id],
      where:
          '${SyncColumns.id} = ? AND menuItemId = ? '
          'AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[scope.variantId, scope.menuItemId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        scope.variantId,
        'variantId',
        'That size does not belong to this menu item',
      );
    }
  }

  static Future<void> _requireInventoryItem(
    DatabaseExecutor db,
    String inventoryItemId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.inventoryItems,
      columns: <String>[SyncColumns.id],
      where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[inventoryItemId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        inventoryItemId,
        'inventoryItemId',
        'That stock item no longer exists',
      );
    }
  }

  static Future<void> _rejectDuplicate(
    DatabaseExecutor db,
    RecipeScope scope,
    String inventoryItemId,
  ) async {
    final List<RecipeIngredient> existing = await _linesFor(db, scope);
    for (final RecipeIngredient ingredient in existing) {
      if (ingredient.inventoryItemId == inventoryItemId) {
        throw ArgumentError.value(
          inventoryItemId,
          'inventoryItemId',
          'This recipe already uses that stock item. Change the quantity on the '
              'existing line instead.',
        );
      }
    }
  }
}
