import 'package:sqflite/sqflite.dart';

import '../../../../money/money.dart';
import '../../../sync/sync_state.dart';
import '../seed/menu_seed_data.dart';
import '../sqlite_tables.dart';
import 'migration.dart';

/// Expresses menu option scope as database relationships instead of as text inside
/// the option name.
///
/// ## The problem this fixes
///
/// Before this migration, a size-dependent option was seeded as three rows named
/// `Extra Cheese (Small)`, `Extra Cheese (Medium)` and `Extra Cheese (Large)`,
/// because `menu_item_options` had one price column and nowhere to record which size
/// a price belonged to. Any screen offering add-ons would have had to parse the name
/// to work out which row applied, which is exactly the kind of implicit contract that
/// breaks silently the first time someone renames an option.
///
/// ## What changes
///
/// Two nullable scope columns are added, and the ten unscoped option rows are retired
/// in favour of rows that carry the scope as a relationship and the plain
/// customisation as the name.
///
/// ## Why the row count grows
///
/// A variant row exists per product and size, so there is no single "Small" to point
/// at: a Small Farmfresh and a Small Cheese Pizza are different variants. Pricing
/// Extra Cheese for Small therefore means one row per pizza. Ten priced option cells
/// on the menu become 170 rows across the seventeen pizzas, plus Ketchup, which is
/// the only option the menu prices flat and so the only global one.
///
/// That is the cost of a correct relationship, and it buys expressiveness the menu
/// does not use yet: a per-pizza add-on price is now possible without a schema
/// change.
class M004ScopedMenuOptions implements Migration {
  const M004ScopedMenuOptions();

  @override
  int get version => 4;

  @override
  String get description => 'Scope menu options by variant and category';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await _addScopeColumns(db);
    await _retireUnscopedOptions(db);
    await seedScopedOptions(db);
  }

  /// Adds the two nullable scope columns and their indexes.
  ///
  /// `ALTER TABLE ADD COLUMN` is used rather than rebuilding the table, so no
  /// existing row is rewritten and nothing can be lost. SQLite permits a `REFERENCES`
  /// clause on an added column provided its default is null, which is the case here,
  /// so the new relationships are enforced from the moment they exist.
  ///
  /// `ON DELETE RESTRICT` matches the rest of the schema: rows are soft-deleted in
  /// normal operation, so a physical delete that would strand an option is refused
  /// rather than silently cascading.
  static Future<void> _addScopeColumns(DatabaseExecutor db) async {
    await db.execute('''
      ALTER TABLE ${SqliteTables.menuItemOptions}
      ADD COLUMN variantId TEXT
      REFERENCES ${SqliteTables.menuItemVariants} (id) ON DELETE RESTRICT
    ''');
    await db.execute('''
      ALTER TABLE ${SqliteTables.menuItemOptions}
      ADD COLUMN categoryId TEXT
      REFERENCES ${SqliteTables.categories} (id) ON DELETE RESTRICT
    ''');

    // Both scopes are looked up on every add-on lookup at the counter.
    await db.execute('''
      CREATE INDEX idx_options_variant
        ON ${SqliteTables.menuItemOptions} (variantId, isDeleted, isActive, displayOrder)
    ''');
    await db.execute('''
      CREATE INDEX idx_options_category
        ON ${SqliteTables.menuItemOptions} (categoryId, isDeleted, isActive, displayOrder)
    ''');
  }

  /// Retires the option rows that carried a size in their name.
  ///
  /// They are soft-deleted rather than dropped, which is the convention everywhere
  /// else in this schema: the row stays available for inspection, the change is
  /// reversible, and it can be transmitted if a backend is added later. Every read
  /// path filters `isDeleted = 0`, so no query can return an option whose name
  /// contains a size.
  ///
  /// Rows are matched by their exact deterministic seed id, so nothing an operator
  /// created can be caught by this. No order references them either: bill lines store
  /// a name and price snapshot, and `order_item_options.optionId` is a nullable
  /// back-reference with no foreign key, so retiring an option cannot alter a
  /// historical bill.
  ///
  /// One caveat worth stating: a price edit made to one of these ten rows between v3
  /// and v4 is not carried across, because a single unscoped row maps to seventeen
  /// scoped ones and there is no non-arbitrary way to distribute it. No menu editing
  /// screen exists yet, so in practice there are no such edits.
  static Future<void> _retireUnscopedOptions(DatabaseExecutor db) async {
    final List<String> ids = MenuSeedData.retiredUnscopedOptionIds;
    if (ids.isEmpty) {
      return;
    }

    final String placeholders = List<String>.filled(ids.length, '?').join(', ');
    await db.rawUpdate(
      'UPDATE ${SqliteTables.menuItemOptions} '
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

  /// Writes the scoped option rows.
  ///
  /// Idempotent in the same way the rest of the seed is: `INSERT OR IGNORE` against a
  /// primary key derived from a fixed slug, so re-running it cannot duplicate a row
  /// and cannot overwrite a price the operator has changed. Exposed so tests can
  /// re-run it directly.
  static Future<void> seedScopedOptions(DatabaseExecutor db) async {
    // Reference data identical on every terminal, so it is marked synced rather than
    // queued for upload.
    final String syncedState = SyncState.synced.name;
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final SeedOption option in MenuSeedData.options) {
      await db.insert(SqliteTables.menuItemOptions, <String, Object?>{
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
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}
