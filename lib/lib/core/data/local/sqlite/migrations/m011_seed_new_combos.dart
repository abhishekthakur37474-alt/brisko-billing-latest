import 'package:sqflite/sqflite.dart';

import '../../../../utils/entity_id.dart';
import '../../../sync/sync_state.dart';
import '../sqlite_tables.dart';
import 'm002_seed_menu.dart';
import 'm004_scoped_menu_options.dart';
import 'migration.dart';

/// Seeds the new combo sets and replaces the global ketchup option with category-scoped ones.
class M011SeedNewCombos implements Migration {
  const M011SeedNewCombos();

  @override
  int get version => 11;

  @override
  String get description =>
      'Seed new combos and scope ketchup options to food categories';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    // Retire the old global ketchup option
    await _retireGlobalKetchup(db);

    // Seed the new products (the two new combos)
    await M002SeedMenu.seed(db);

    // Seed the new scoped options (the category-scoped ketchup options)
    await M004ScopedMenuOptions.seedScopedOptions(db);
  }

  static Future<void> _retireGlobalKetchup(DatabaseExecutor db) async {
    await db.rawUpdate(
      'UPDATE ${SqliteTables.menuItemOptions} '
      'SET ${SyncColumns.isDeleted} = 1, '
      '    ${SyncColumns.updatedAt} = ?, '
      '    ${SyncColumns.syncState} = ? '
      'WHERE ${SyncColumns.id} = ?',
      <Object?>[
        DateTime.now().toUtc().millisecondsSinceEpoch,
        SyncState.pending.name,
        EntityId.seeded('opt', 'ketchup'),
      ],
    );
  }
}
