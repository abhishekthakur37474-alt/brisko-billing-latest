import 'package:sqflite/sqflite.dart';

import '../../../../money/money.dart';
import '../../../sync/sync_state.dart';
import '../seed/menu_seed_data.dart';
import '../seed/menu_spec_data.dart';
import '../sqlite_tables.dart';
import 'migration.dart';

/// Replaces the earlier printed-menu seed with the client's supplied menu
/// specification, in place and without touching operator data or existing bills.
///
/// ## Why this is a replacement, not another additive seed
///
/// The supplied specification is a different price list from the seed that shipped
/// in [MenuSeedData]: Cheese Pizza's Large is 390 rather than 400, Cheese & Tomato
/// is 130/250/390 rather than 200/310/480, Farmfresh is renamed Farmhouse, Tandoori
/// Paneer Pizza is gone, and there are sixteen printed sections rather than twelve.
/// The two cannot both be true, and the specification is the authority. This
/// migration is therefore the one migration that is allowed to overwrite the values
/// of rows the seed previously wrote, and to retire seed rows that the new menu does
/// not contain.
///
/// ## What it never touches
///
/// * Operator-created rows. They use random ids from `EntityId.generate`, never the
///   `EntityId.seeded` ids this migration matches on.
/// * Historical bills. Bill lines store a name-and-price snapshot, and
///   `order_item_options.optionId` is a nullable back-reference with no foreign key,
///   so retiring a reference row cannot alter a past bill.
/// * Existing orders, payments, refunds, outbox rows or settings. No other table is
///   read or written.
///
/// ## Idempotency
///
/// Every write is an upsert keyed on a deterministic id, and the retirement pass
/// computes its targets by set difference, so running this migration twice leaves
/// the same rows in the same state. That is what lets a partially applied upgrade be
/// retried.
///
/// ## Sync state
///
/// The specification rows are reference data identical on every terminal, so they
/// carry `synced`, matching every other seed. Rows retired here carry `pending`, so
/// the removal can propagate, matching how `M004ScopedMenuOptions` and
/// `M011SeedNewCombos` retire rows.
class M015SpecMenu implements Migration {
  const M015SpecMenu();

  @override
  int get version => 15;

  @override
  String get description =>
      'Replace the seeded menu with the supplied Brisko menu specification';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await retireLegacyRows(db);
    await seedSpecMenu(db);
  }

  /// Soft-deletes seed rows that the specification does not carry.
  ///
  /// The targets are the difference between the ids the old seed could create and
  /// the ids the specification defines, so a row that survives into the new menu is
  /// never retired. Only ids with the `EntityId.seeded` prefix are candidates, which
  /// is what keeps operator-created menu rows out of scope.
  static Future<void> retireLegacyRows(DatabaseExecutor db) async {
    final Set<String> keep = <String>{
      for (final SeedCategory category in MenuSpecData.categories) category.id,
      for (final SeedMenuItem item in MenuSpecData.items) item.id,
      for (final SeedVariant variant in MenuSpecData.variants) variant.id,
      for (final SeedOption option in MenuSpecData.options) option.id,
    };

    await _retireMissing(
      db,
      SqliteTables.menuItemOptions,
      MenuSeedData.options.map((SeedOption option) => option.id),
      keep,
    );
    await _retireMissing(
      db,
      SqliteTables.menuItemVariants,
      MenuSeedData.variants.map((SeedVariant variant) => variant.id),
      keep,
    );
    await _retireMissing(
      db,
      SqliteTables.menuItems,
      MenuSeedData.items.map((SeedMenuItem item) => item.id),
      keep,
    );
    await _retireMissing(
      db,
      SqliteTables.categories,
      MenuSeedData.categories.map((SeedCategory category) => category.id),
      keep,
    );
  }

  static Future<void> _retireMissing(
    DatabaseExecutor db,
    String table,
    Iterable<String> candidates,
    Set<String> keep,
  ) async {
    final List<String> ids = candidates
        .where((String id) => !keep.contains(id))
        .toList();
    if (ids.isEmpty) {
      return;
    }

    final String placeholders = List<String>.filled(ids.length, '?').join(', ');
    await db.rawUpdate(
      'UPDATE $table '
      'SET ${SyncColumns.isDeleted} = 1, '
      '    ${SyncColumns.updatedAt} = ?, '
      '    ${SyncColumns.syncState} = ? '
      'WHERE ${SyncColumns.id} IN ($placeholders)',
      <Object?>[
        DateTime.now().toUtc().millisecondsSinceEpoch,
        SyncState.pending.name,
        ...ids,
      ],
    );
  }

  /// Writes the specification's categories, products, variants and options.
  ///
  /// Each row is inserted if absent and then updated unconditionally, rather than
  /// using `INSERT OR REPLACE`. A replace deletes and re-inserts, which with
  /// `ON DELETE RESTRICT` would refuse to overwrite a product that still has variant
  /// or option children. Insert-then-update changes the row in place, so the children
  /// keep pointing at it.
  static Future<void> seedSpecMenu(DatabaseExecutor db) async {
    final String syncedState = SyncState.synced.name;
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final SeedCategory category in MenuSpecData.categories) {
      await _upsert(db, SqliteTables.categories, <String, Object?>{
        SyncColumns.id: category.id,
        SyncColumns.createdAt: now,
        SyncColumns.updatedAt: now,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: syncedState,
        'name': category.name,
        'displayOrder': category.displayOrder,
        'isActive': 1,
      });
    }

    for (final SeedMenuItem item in MenuSpecData.items) {
      await _upsert(db, SqliteTables.menuItems, <String, Object?>{
        SyncColumns.id: item.id,
        SyncColumns.createdAt: now,
        SyncColumns.updatedAt: now,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: syncedState,
        'categoryId': item.categoryId,
        'name': item.name,
        'description': item.description,
        'itemType': item.itemTypeName,
        'basePricePaise': Money.parse(item.basePriceRupees).paise,
        'isAvailable': 1,
        'isActive': 1,
        'displayOrder': item.displayOrder,
      });
    }

    for (final SeedVariant variant in MenuSpecData.variants) {
      await _upsert(db, SqliteTables.menuItemVariants, <String, Object?>{
        SyncColumns.id: variant.id,
        SyncColumns.createdAt: now,
        SyncColumns.updatedAt: now,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: syncedState,
        'menuItemId': variant.menuItemId,
        'name': variant.name,
        'pricePaise': Money.parse(variant.priceRupees).paise,
        'displayOrder': variant.displayOrder,
        'isActive': 1,
      });
    }

    for (final SeedOption option in MenuSpecData.options) {
      await _upsert(db, SqliteTables.menuItemOptions, <String, Object?>{
        SyncColumns.id: option.id,
        SyncColumns.createdAt: now,
        SyncColumns.updatedAt: now,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: syncedState,
        'menuItemId': option.menuItemId,
        'variantId': option.variantId,
        'categoryId': option.categoryId,
        'name': option.name,
        'optionType': option.optionTypeName,
        'pricePaise': Money.parse(option.priceRupees).paise,
        'displayOrder': option.displayOrder,
        'isActive': 1,
      });
    }
  }

  static Future<void> _upsert(
    DatabaseExecutor db,
    String table,
    Map<String, Object?> values,
  ) async {
    await db.insert(
      table,
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // `createdAt` records when the row first appeared and must survive an update, so
    // it is dropped from the update set along with the primary key.
    final Map<String, Object?> updates = Map<String, Object?>.from(values)
      ..remove(SyncColumns.id)
      ..remove(SyncColumns.createdAt);

    await db.update(
      table,
      updates,
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[values[SyncColumns.id]],
    );
  }
}
