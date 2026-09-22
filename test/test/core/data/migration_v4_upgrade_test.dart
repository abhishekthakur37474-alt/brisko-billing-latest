import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/seed/menu_seed_data.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal already running v3 upgrades to v4 correctly, and ends up
/// with the same menu as a database created fresh today.
///
/// This is the case that cannot be inferred from the other tests: every other test
/// opens a database that goes straight to the latest version, so it never exercises
/// `onUpgrade` or the retirement of the unscoped option rows. Here a genuine v3
/// database is built first, complete with the ten size-in-name option rows that v3
/// really did insert, and then opened by the current build.
void main() {
  setUpAll(TestDatabase.register);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v4_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion3Database(path);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v3 database upgrades to v4 without losing menu data', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);
    final SqliteMenuRepository repository = SqliteMenuRepository(
      database: database,
    );

    // Whatever version this build defines, not a pinned number: the point of the
    // test is that a v3 terminal reaches the current schema with its menu intact.
    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);

    // Products and variants are untouched by v4.
    expect((await repository.loadCategories()).valueOrNull, hasLength(12));
    expect((await repository.loadItems()).valueOrNull, hasLength(66));

    final List<MenuItem> items = (await repository.loadItems()).valueOrNull!;
    final MenuItem cheesePizza = items.firstWhere(
      (MenuItem i) => i.name == 'Cheese Pizza',
    );
    final List<MenuItemVariant> sizes = (await repository.loadVariants(
      cheesePizza.id,
    )).valueOrNull!;

    expect(sizes, hasLength(3));
    expect(
      sizes.firstWhere((MenuItemVariant v) => v.name == 'Medium').price,
      Money.parse('250'),
    );
  });

  test('the ten unscoped option rows are retired, not deleted', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> retired = await database.database.query(
      SqliteTables.menuItemOptions,
      where:
          'id IN (${List<String>.filled(MenuSeedData.retiredUnscopedOptionIds.length, '?').join(', ')})',
      whereArgs: MenuSeedData.retiredUnscopedOptionIds,
    );

    expect(retired, hasLength(10));
    // Still physically present, so the change is reversible and transmittable.
    expect(
      retired.every((Map<String, Object?> row) => row['isDeleted'] == 1),
      isTrue,
    );
    // Marked as an unsent change rather than left claiming to be synced.
    expect(
      retired.every(
        (Map<String, Object?> row) => row['syncState'] == 'pending',
      ),
      isTrue,
    );
  });

  test(
    'no option carrying a size in its name is readable after upgrade',
    () async {
      final SqliteDatabase database = await TestDatabase.openOnDisk(path);
      addTearDown(database.close);
      final SqliteMenuRepository repository = SqliteMenuRepository(
        database: database,
      );

      final List<MenuItemOption> visible =
          (await repository.loadAllOptions()).valueOrNull!;

      expect(visible, hasLength(179));
      expect(
        visible.every((MenuItemOption o) => !o.name.contains('(')),
        isTrue,
      );
      expect(visible.map((MenuItemOption o) => o.name).toSet(), <String>{
        'Thin Crust',
        'Cheese Burst',
        'Extra Cheese',
        'Extra Toppings',
        'Ketchup',
      });
    },
  );

  test('an upgraded database answers size queries like a fresh one', () async {
    final SqliteDatabase upgraded = await TestDatabase.openOnDisk(path);
    addTearDown(upgraded.close);
    final SqliteMenuRepository upgradedMenu = SqliteMenuRepository(
      database: upgraded,
    );

    final SqliteDatabase fresh = await TestDatabase.openInMemory();
    addTearDown(fresh.close);
    final SqliteMenuRepository freshMenu = SqliteMenuRepository(
      database: fresh,
    );

    Future<Map<String, Money>> pricesFor(
      SqliteMenuRepository menu,
      String size,
    ) async {
      final MenuItem pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem i) => i.name == 'Farmfresh',
      );
      final MenuItemVariant variant = (await menu.loadVariants(pizza.id))
          .valueOrNull!
          .firstWhere((MenuItemVariant v) => v.name == size);
      final List<MenuItemOption> options = (await menu.loadOptionsForVariant(
        variant.id,
      )).valueOrNull!;
      return <String, Money>{
        for (final MenuItemOption option in options) option.name: option.price,
      };
    }

    for (final String size in <String>['Small', 'Medium', 'Large']) {
      expect(
        await pricesFor(upgradedMenu, size),
        await pricesFor(freshMenu, size),
        reason: 'upgraded and fresh must agree at $size',
      );
    }

    // And the values are the printed ones.
    expect(
      (await pricesFor(upgradedMenu, 'Medium'))['Extra Cheese'],
      Money.parse('70'),
    );
    expect(
      (await pricesFor(upgradedMenu, 'Large')).containsKey('Cheese Burst'),
      isFalse,
    );
  });
}

/// Builds a database in exactly the state migration v3 left it in.
///
/// The three shipped migrations are replayed, then the ten unscoped option rows are
/// inserted by hand. That last step is necessary because option seeding has since
/// moved to v4, so replaying v2 and v3 alone no longer produces them; writing them
/// here reproduces what a real terminal actually holds.
Future<void> _createVersion3Database(String path) async {
  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 3,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await _insertUnscopedOptions(db);
      },
    ),
  );
  await database.close();
}

/// The option rows as v3 wrote them: one price per row, size in the name.
Future<void> _insertUnscopedOptions(DatabaseExecutor db) async {
  const List<List<Object>> rows = <List<Object>>[
    <Object>['opt-thin-crust-small', 'Thin Crust (Small)', 'crust', 3000, 10],
    <Object>['opt-thin-crust-medium', 'Thin Crust (Medium)', 'crust', 5000, 11],
    <Object>[
      'opt-cheese-burst-small',
      'Cheese Burst (Small)',
      'crust',
      8000,
      20,
    ],
    <Object>[
      'opt-cheese-burst-medium',
      'Cheese Burst (Medium)',
      'crust',
      9000,
      21,
    ],
    <Object>[
      'opt-extra-cheese-small',
      'Extra Cheese (Small)',
      'addOn',
      5000,
      30,
    ],
    <Object>[
      'opt-extra-cheese-medium',
      'Extra Cheese (Medium)',
      'addOn',
      7000,
      31,
    ],
    <Object>[
      'opt-extra-cheese-large',
      'Extra Cheese (Large)',
      'addOn',
      9000,
      32,
    ],
    <Object>[
      'opt-extra-toppings-small',
      'Extra Toppings (Small)',
      'addOn',
      3000,
      40,
    ],
    <Object>[
      'opt-extra-toppings-medium',
      'Extra Toppings (Medium)',
      'addOn',
      5000,
      41,
    ],
    <Object>[
      'opt-extra-toppings-large',
      'Extra Toppings (Large)',
      'addOn',
      7000,
      42,
    ],
  ];

  for (final List<Object> row in rows) {
    await db.insert(SqliteTables.menuItemOptions, <String, Object?>{
      'id': row[0],
      'createdAt': 0,
      'updatedAt': 0,
      'isDeleted': 0,
      'syncState': 'synced',
      'name': row[1],
      'optionType': row[2],
      'pricePaise': row[3],
      'displayOrder': row[4],
      'isActive': 1,
    });
  }
}
