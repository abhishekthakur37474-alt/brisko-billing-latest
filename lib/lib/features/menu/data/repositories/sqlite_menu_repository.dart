import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/menu_category.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_option.dart';
import '../../domain/models/menu_item_variant.dart';
import '../../domain/repositories/menu_repository.dart';

/// SQLite implementation of [MenuRepository].
///
/// Generic CRUD is delegated to [SqliteLocalStore]; the queries below are the ones
/// that are genuinely menu-shaped, such as resolving which options apply to an
/// item. All SQL for the menu lives in this file and nowhere else.
class SqliteMenuRepository implements MenuRepository {
  SqliteMenuRepository({required SqliteDatabase database})
    : _database = database,
      _categories = SqliteLocalStore<MenuCategory>(
        database: database,
        table: SqliteTables.categories,
        fromRow: MenuCategory.fromRow,
        orderBy: 'displayOrder ASC, name ASC',
      ),
      _items = SqliteLocalStore<MenuItem>(
        database: database,
        table: SqliteTables.menuItems,
        fromRow: MenuItem.fromRow,
        orderBy: 'displayOrder ASC, name ASC',
      ),
      _variants = SqliteLocalStore<MenuItemVariant>(
        database: database,
        table: SqliteTables.menuItemVariants,
        fromRow: MenuItemVariant.fromRow,
        orderBy: 'displayOrder ASC',
      ),
      _options = SqliteLocalStore<MenuItemOption>(
        database: database,
        table: SqliteTables.menuItemOptions,
        fromRow: MenuItemOption.fromRow,
        orderBy: 'displayOrder ASC, name ASC',
      );

  final SqliteDatabase _database;
  final SqliteLocalStore<MenuCategory> _categories;
  final SqliteLocalStore<MenuItem> _items;
  final SqliteLocalStore<MenuItemVariant> _variants;
  final SqliteLocalStore<MenuItemOption> _options;

  Database get _db => _database.database;

  @override
  Future<Result<List<MenuCategory>>> loadCategories() {
    return SqliteErrorMapper.guard<List<MenuCategory>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.categories,
        where: 'isDeleted = 0 AND isActive = 1',
        orderBy: 'displayOrder ASC, name ASC',
      );
      return rows.map(MenuCategory.fromRow).toList(growable: false);
    }, context: 'load the menu categories');
  }

  @override
  Stream<List<MenuCategory>> watchCategories() => _categories.watchAll();

  @override
  Future<Result<List<MenuCategory>>> loadCategoriesForManagement() {
    return SqliteErrorMapper.guard<List<MenuCategory>>(() async {
      // No isActive filter: maintenance has to see a switched-off category to switch
      // it back on. isDeleted = 0 stays, because a removed row is meant to be gone.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.categories,
        where: 'isDeleted = 0',
        orderBy: 'displayOrder ASC, name ASC',
      );
      return rows.map(MenuCategory.fromRow).toList(growable: false);
    }, context: 'load the categories for management');
  }

  @override
  Future<Result<List<MenuItem>>> loadItems({String? categoryId}) {
    return SqliteErrorMapper.guard<List<MenuItem>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItems,
        where: categoryId == null
            ? 'isDeleted = 0 AND isActive = 1'
            : 'isDeleted = 0 AND isActive = 1 AND categoryId = ?',
        whereArgs: categoryId == null ? null : <Object?>[categoryId],
        orderBy: 'displayOrder ASC, name ASC',
      );
      return rows.map(MenuItem.fromRow).toList(growable: false);
    }, context: 'load the menu items');
  }

  @override
  Future<Result<List<MenuItem>>> loadItemsForManagement({String? categoryId}) {
    return SqliteErrorMapper.guard<List<MenuItem>>(() async {
      // Deactivated and unavailable items are both returned: the screen shows every
      // state so any of them can be changed. Only a removal hides a row.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItems,
        where: categoryId == null
            ? 'isDeleted = 0'
            : 'isDeleted = 0 AND categoryId = ?',
        whereArgs: categoryId == null ? null : <Object?>[categoryId],
        orderBy: 'displayOrder ASC, name ASC',
      );
      return rows.map(MenuItem.fromRow).toList(growable: false);
    }, context: 'load the menu items for management');
  }

  @override
  Future<Result<MenuItem?>> findItem(String id) => _items.findById(id);

  @override
  Future<Result<List<MenuItemVariant>>> loadVariants(String menuItemId) {
    return SqliteErrorMapper.guard<List<MenuItemVariant>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemVariants,
        where: 'isDeleted = 0 AND isActive = 1 AND menuItemId = ?',
        whereArgs: <Object?>[menuItemId],
        orderBy: 'displayOrder ASC',
      );
      return rows.map(MenuItemVariant.fromRow).toList(growable: false);
    }, context: 'load the item sizes');
  }

  @override
  Future<Result<List<MenuItemVariant>>> loadVariantsForManagement(
    String menuItemId,
  ) {
    return SqliteErrorMapper.guard<List<MenuItemVariant>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemVariants,
        where: 'isDeleted = 0 AND menuItemId = ?',
        whereArgs: <Object?>[menuItemId],
        orderBy: 'displayOrder ASC',
      );
      return rows.map(MenuItemVariant.fromRow).toList(growable: false);
    }, context: 'load the item sizes for management');
  }

  @override
  Future<Result<List<MenuItemOption>>> loadOptionsForVariant(String variantId) {
    return SqliteErrorMapper.guard<List<MenuItemOption>>(() async {
      // Resolve the variant to its product and category, so category-scoped and
      // item-scoped options can be included without the caller supplying them.
      final List<Map<String, Object?>> owner = await _db.rawQuery(
        '''
        SELECT v.menuItemId AS menuItemId, i.categoryId AS categoryId
        FROM ${SqliteTables.menuItemVariants} v
        JOIN ${SqliteTables.menuItems} i ON i.id = v.menuItemId
        WHERE v.id = ? AND v.isDeleted = 0
        LIMIT 1
      ''',
        <Object?>[variantId],
      );

      if (owner.isEmpty) {
        // Unknown or deleted variant. Only genuinely global options can apply.
        return _resolve(await _globalOptionRows());
      }

      final String menuItemId = owner.first['menuItemId']! as String;
      final String categoryId = owner.first['categoryId']! as String;

      // Each branch pins the narrower scope columns to NULL, so a row priced for a
      // different variant cannot leak in through the item or category branch.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemOptions,
        where:
            'isDeleted = 0 AND isActive = 1 AND ('
            'variantId = ? '
            'OR (variantId IS NULL AND menuItemId = ?) '
            'OR (variantId IS NULL AND menuItemId IS NULL AND categoryId = ?) '
            'OR (variantId IS NULL AND menuItemId IS NULL AND categoryId IS NULL)'
            ')',
        whereArgs: <Object?>[variantId, menuItemId, categoryId],
      );

      return _resolve(rows);
    }, context: 'load the options for this size');
  }

  @override
  Future<Result<List<MenuItemOption>>> loadOptionsForItem(String menuItemId) {
    return SqliteErrorMapper.guard<List<MenuItemOption>>(() async {
      final List<Map<String, Object?>> category = await _db.query(
        SqliteTables.menuItems,
        columns: <String>['categoryId'],
        where: 'id = ? AND isDeleted = 0',
        whereArgs: <Object?>[menuItemId],
        limit: 1,
      );

      if (category.isEmpty) {
        return _resolve(await _globalOptionRows());
      }

      // variantId IS NULL throughout: an option whose price depends on the size
      // cannot be offered until a size is chosen, so it is excluded here rather
      // than returned at an arbitrary size's price.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemOptions,
        where:
            'isDeleted = 0 AND isActive = 1 AND variantId IS NULL AND ('
            'menuItemId = ? '
            'OR (menuItemId IS NULL AND categoryId = ?) '
            'OR (menuItemId IS NULL AND categoryId IS NULL)'
            ')',
        whereArgs: <Object?>[menuItemId, category.first['categoryId']],
      );

      return _resolve(rows);
    }, context: 'load the item options');
  }

  Future<List<Map<String, Object?>>> _globalOptionRows() {
    return _db.query(
      SqliteTables.menuItemOptions,
      where:
          'isDeleted = 0 AND isActive = 1 '
          'AND variantId IS NULL AND menuItemId IS NULL AND categoryId IS NULL',
    );
  }

  /// Collapses overlapping scopes and sorts the result for display.
  ///
  /// Two rows sharing a name are two prices for the same customisation reached
  /// through different scopes, so the narrower one is kept. Without this the counter
  /// could be shown Extra Cheese twice at different prices and no way to choose.
  static List<MenuItemOption> _resolve(List<Map<String, Object?>> rows) {
    final Map<String, MenuItemOption> narrowest = <String, MenuItemOption>{};

    for (final Map<String, Object?> row in rows) {
      final MenuItemOption option = MenuItemOption.fromRow(row);
      final MenuItemOption? existing = narrowest[option.name];
      if (existing == null ||
          option.scope.specificity > existing.scope.specificity) {
        narrowest[option.name] = option;
      }
    }

    // Sorted here rather than in SQL because deduplication happens after the query.
    final List<MenuItemOption> resolved = narrowest.values.toList();
    resolved.sort((MenuItemOption a, MenuItemOption b) {
      final int byType = a.optionType.index.compareTo(b.optionType.index);
      if (byType != 0) {
        return byType;
      }
      final int byOrder = a.displayOrder.compareTo(b.displayOrder);
      return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
    });
    return List<MenuItemOption>.unmodifiable(resolved);
  }

  @override
  Future<Result<List<MenuItemOption>>> loadAllOptions() {
    return SqliteErrorMapper.guard<List<MenuItemOption>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemOptions,
        where: 'isDeleted = 0 AND isActive = 1',
        orderBy: 'optionType ASC, displayOrder ASC, name ASC',
      );
      return rows.map(MenuItemOption.fromRow).toList(growable: false);
    }, context: 'load the menu options');
  }

  @override
  Future<Result<List<MenuItemOption>>> loadOptionsForManagement() {
    return SqliteErrorMapper.guard<List<MenuItemOption>>(() async {
      // No isActive filter, and no scope resolution: management edits the rows as they
      // are stored, one per scope, so a deactivated option can be turned back on and a
      // size-specific price is shown as itself rather than collapsed into another.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.menuItemOptions,
        where: 'isDeleted = 0',
        orderBy: 'optionType ASC, displayOrder ASC, name ASC',
      );
      return rows.map(MenuItemOption.fromRow).toList(growable: false);
    }, context: 'load the menu options for management');
  }

  @override
  Future<Result<void>> saveCategory(MenuCategory category) =>
      _categories.save(category);

  @override
  Future<Result<void>> saveItem(MenuItem item) => _items.save(item);

  @override
  Future<Result<void>> saveVariant(MenuItemVariant variant) =>
      _variants.save(variant);

  @override
  Future<Result<void>> saveOption(MenuItemOption option) =>
      _options.save(option);

  @override
  Future<Result<void>> deleteCategory(String id) => _categories.softDelete(id);

  @override
  Future<Result<void>> deleteItem(String id) => _items.softDelete(id);
}
