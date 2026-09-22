import 'package:sqflite/sqflite.dart';

import '../../../../money/money.dart';
import '../../../sync/sync_state.dart';
import '../seed/menu_seed_data.dart';
import '../sqlite_tables.dart';
import 'migration.dart';

/// Seeds the real Brisko Pizza menu: categories, products and size variants.
///
/// Options are not seeded here. They are scoped by `variantId`, a column that
/// migration v4 adds, so v4 owns them. See [seed] for why that keeps a fresh install
/// and an upgraded one identical.
///
/// ## Idempotency
///
/// Every insert is `INSERT OR IGNORE` against a primary key derived from a fixed
/// slug, so the key itself is the deduplication mechanism. Running this seed any
/// number of times produces the same rows. That property is tested directly, and
/// it is what allows the seed to be re-run to repair a partially loaded menu
/// without risking duplicate products in the till.
///
/// It follows that this migration will not *update* an existing row. Correcting a
/// price that has already shipped needs a new migration issuing an explicit
/// `UPDATE`, which is deliberate: a silent overwrite of live menu data should be a
/// decision someone makes on purpose.
///
/// ## Operator-created data is untouched
///
/// The seed only writes rows whose ids come from `EntityId.seeded`. Products the
/// operator adds through the menu screen use random ids and are never affected.
class M002SeedMenu implements Migration {
  const M002SeedMenu();

  @override
  int get version => 2;

  @override
  String get description => 'Seed real Brisko Pizza menu';

  @override
  Future<void> migrate(DatabaseExecutor db) => seed(db);

  /// Applies the seed. Exposed separately from [migrate] so it can be invoked
  /// again, and so its idempotency can be tested without driving a schema upgrade.
  static Future<void> seed(DatabaseExecutor db) async {
    // Seed rows are reference data that exists identically on every terminal, so
    // they are marked synced rather than queued in the outbox. Queuing them would
    // push the same menu to the cloud from every install for no benefit.
    const String syncedState = 'synced';
    assert(
      syncedState == 'synced' && SyncState.synced.name == syncedState,
      'SyncState.synced was renamed; update the seed',
    );

    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final SeedCategory category in MenuSeedData.categories) {
      await db.insert(SqliteTables.categories, <String, Object?>{
        SyncColumns.id: category.id,
        SyncColumns.createdAt: now,
        SyncColumns.updatedAt: now,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: syncedState,
        'name': category.name,
        'displayOrder': category.displayOrder,
        'isActive': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    for (final SeedMenuItem item in MenuSeedData.items) {
      await db.insert(SqliteTables.menuItems, <String, Object?>{
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
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    for (final SeedVariant variant in MenuSeedData.variants) {
      await db.insert(SqliteTables.menuItemVariants, <String, Object?>{
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
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    // Options are seeded by migration v4, not here. They need the `variantId` and
    // `categoryId` scope columns, which v4 is the migration that adds, so writing
    // them at this point would fail against the v1 table on a fresh install.
    //
    // Both paths still converge on the same rows: a fresh install gets them when v4
    // runs a moment later, and an upgraded install gets them when v4 replaces the
    // unscoped rows that v2 and v3 had inserted.
  }
}
