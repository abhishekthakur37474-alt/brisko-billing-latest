import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_scope.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

/// Verifies that option scope is resolved through database relationships, and that
/// the billing layer can get the right price for a chosen size without knowing how
/// scope is stored.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository repository;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    repository = SqliteMenuRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  Future<MenuItem> itemNamed(String name) async {
    final List<MenuItem> items = (await repository.loadItems()).valueOrNull!;
    return items.firstWhere((MenuItem item) => item.name == name);
  }

  Future<MenuItemVariant> variantOf(String itemName, String size) async {
    final MenuItem item = await itemNamed(itemName);
    final List<MenuItemVariant> variants = (await repository.loadVariants(
      item.id,
    )).valueOrNull!;
    return variants.firstWhere((MenuItemVariant v) => v.name == size);
  }

  Future<Map<String, Money>> optionsForSize(
    String itemName,
    String size,
  ) async {
    final MenuItemVariant variant = await variantOf(itemName, size);
    final List<MenuItemOption> options =
        (await repository.loadOptionsForVariant(variant.id)).valueOrNull!;
    return <String, Money>{
      for (final MenuItemOption option in options) option.name: option.price,
    };
  }

  group('size-specific pricing through variantId', () {
    test('a Small pizza gets the Small prices', () async {
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Small',
      );

      expect(options['Extra Cheese'], Money.parse('50'));
      expect(options['Extra Toppings'], Money.parse('30'));
      expect(options['Thin Crust'], Money.parse('30'));
      expect(options['Cheese Burst'], Money.parse('80'));
      expect(options['Ketchup'], Money.parse('10'));
    });

    test('a Medium pizza gets the Medium prices', () async {
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Medium',
      );

      expect(options['Extra Cheese'], Money.parse('70'));
      expect(options['Extra Toppings'], Money.parse('50'));
      expect(options['Thin Crust'], Money.parse('50'));
      expect(options['Cheese Burst'], Money.parse('90'));
      expect(options['Ketchup'], Money.parse('10'));
    });

    test('a Large pizza gets the Large prices', () async {
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Large',
      );

      expect(options['Extra Cheese'], Money.parse('90'));
      expect(options['Extra Toppings'], Money.parse('70'));
      expect(options['Ketchup'], Money.parse('10'));
    });

    test('every pizza is priced the same way at each size', () async {
      // The menu prices these uniformly across pizzas, so all seventeen must agree.
      for (final String pizza in <String>[
        'Cheese Pizza',
        'Double Cheese Pizza',
        'Spicy Paneer',
        'Tandoori Paneer Pizza',
      ]) {
        expect(
          (await optionsForSize(pizza, 'Small'))['Extra Cheese'],
          Money.parse('50'),
          reason: '$pizza Small',
        );
        expect(
          (await optionsForSize(pizza, 'Medium'))['Extra Cheese'],
          Money.parse('70'),
          reason: '$pizza Medium',
        );
        expect(
          (await optionsForSize(pizza, 'Large'))['Extra Cheese'],
          Money.parse('90'),
          reason: '$pizza Large',
        );
      }
    });

    test(
      'the caller never sees a size in a name or has to read a scope',
      () async {
        final MenuItemVariant medium = await variantOf(
          'Wonder Pizza',
          'Medium',
        );
        final List<MenuItemOption> options =
            (await repository.loadOptionsForVariant(medium.id)).valueOrNull!;

        expect(options.map((MenuItemOption o) => o.name), <String>[
          'Thin Crust',
          'Cheese Burst',
          'Extra Cheese',
          'Extra Toppings',
          'Ketchup',
        ]);
        expect(
          options.every((MenuItemOption o) => !o.name.contains('(')),
          isTrue,
        );
      },
    );

    test('options are grouped by kind then printed order', () async {
      final MenuItemVariant small = await variantOf('Country Feast', 'Small');
      final List<MenuItemOption> options =
          (await repository.loadOptionsForVariant(small.id)).valueOrNull!;

      expect(options.map((MenuItemOption o) => o.optionType), <MenuOptionType>[
        MenuOptionType.crust,
        MenuOptionType.crust,
        MenuOptionType.addOn,
        MenuOptionType.addOn,
        MenuOptionType.condiment,
      ]);
    });
  });

  group('prices the menu does not print are not invented', () {
    test('a Large pizza is offered no Thin Crust', () async {
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Large',
      );

      expect(options.containsKey('Thin Crust'), isFalse);
    });

    test('a Large pizza is offered no Cheese Burst', () async {
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Large',
      );

      expect(options.containsKey('Cheese Burst'), isFalse);
    });

    test('no Large crust row exists anywhere in the table', () async {
      final List<MenuItemVariant> larges = <MenuItemVariant>[
        for (final String pizza in <String>['Cheese Pizza', 'Achari Pizza'])
          await variantOf(pizza, 'Large'),
      ];

      for (final MenuItemVariant large in larges) {
        final List<Map<String, Object?>> rows = await database.database.query(
          SqliteTables.menuItemOptions,
          where: 'variantId = ? AND optionType = ?',
          whereArgs: <Object?>[large.id, MenuOptionType.crust.name],
        );
        expect(rows, isEmpty);
      }
    });

    test('a Large pizza still gets the size-independent option', () async {
      // Missing crust prices must not suppress Ketchup.
      final Map<String, Money> options = await optionsForSize(
        'Farmfresh',
        'Large',
      );
      expect(options['Ketchup'], Money.parse('10'));
    });
  });

  group('variant scoping is exclusive', () {
    test(
      'an option priced for one variant is not offered on another',
      () async {
        final MenuItemVariant mediumFarm = await variantOf(
          'Farmfresh',
          'Medium',
        );
        final MenuItem wrap = await itemNamed('Paneer Wrap');

        // A one-off priced for that Medium pizza only.
        await repository.saveOption(
          Fixtures.option(
            variantId: mediumFarm.id,
            name: 'Test Truffle Oil',
            price: '45.00',
            displayOrder: 99,
          ),
        );

        final Map<String, Money> onThatVariant = await optionsForSize(
          'Farmfresh',
          'Medium',
        );
        expect(onThatVariant['Test Truffle Oil'], Money.parse('45.00'));

        // Not on a different size of the same pizza.
        final Map<String, Money> onAnotherSize = await optionsForSize(
          'Farmfresh',
          'Large',
        );
        expect(onAnotherSize.containsKey('Test Truffle Oil'), isFalse);

        // Not on a different pizza at the same size.
        final Map<String, Money> onAnotherPizza = await optionsForSize(
          'Wonder Pizza',
          'Medium',
        );
        expect(onAnotherPizza.containsKey('Test Truffle Oil'), isFalse);

        // Not on a product with no sizes at all.
        final List<MenuItemOption> onWrap =
            (await repository.loadOptionsForItem(wrap.id)).valueOrNull!;
        expect(
          onWrap.map((MenuItemOption o) => o.name),
          isNot(contains('Test Truffle Oil')),
        );
      },
    );

    test(
      'an unknown variant yields global options only, not an error',
      () async {
        final Object result = await repository.loadOptionsForVariant(
          'var-nope',
        );

        expect((result as dynamic).isOk, isTrue);
        final List<MenuItemOption> options =
            (await repository.loadOptionsForVariant('var-nope')).valueOrNull!;
        expect(options.map((MenuItemOption o) => o.name), <String>['Ketchup']);
      },
    );
  });

  group('category scoping', () {
    test(
      'applies to every product in the category and nothing outside it',
      () async {
        final List<MenuCategory> categories =
            (await repository.loadCategories()).valueOrNull!;
        final MenuCategory burgers = categories.firstWhere(
          (MenuCategory c) => c.name == 'Burger',
        );

        await repository.saveOption(
          Fixtures.option(
            categoryId: burgers.id,
            name: 'Test Extra Patty',
            price: '35.00',
            displayOrder: 98,
          ),
        );

        // Every burger sees it.
        for (final String burger in <String>[
          'Potato Burger',
          'Paneer Burger',
        ]) {
          final MenuItem item = await itemNamed(burger);
          final List<MenuItemOption> offered =
              (await repository.loadOptionsForItem(item.id)).valueOrNull!;
          expect(
            offered.map((MenuItemOption o) => o.name),
            contains('Test Extra Patty'),
            reason: burger,
          );
        }

        // Nothing outside the category does.
        final MenuItem wrap = await itemNamed('Paneer Wrap');
        final List<MenuItemOption> onWrap =
            (await repository.loadOptionsForItem(wrap.id)).valueOrNull!;
        expect(
          onWrap.map((MenuItemOption o) => o.name),
          isNot(contains('Test Extra Patty')),
        );
      },
    );

    test('reaches a variant through its product category', () async {
      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;
      final MenuCategory pizzas = categories.firstWhere(
        (MenuCategory c) => c.name == 'Veg Pizza',
      );

      await repository.saveOption(
        Fixtures.option(
          categoryId: pizzas.id,
          name: 'Test Oregano Sachet',
          price: '5.00',
          displayOrder: 97,
        ),
      );

      // Offered at every size, because it does not depend on size.
      for (final String size in <String>['Small', 'Medium', 'Large']) {
        final Map<String, Money> options = await optionsForSize(
          'Garden Fresh',
          size,
        );
        expect(
          options['Test Oregano Sachet'],
          Money.parse('5.00'),
          reason: size,
        );
      }
    });

    test('records itself as category scoped', () async {
      final MenuCategory taco = (await repository.loadCategories()).valueOrNull!
          .firstWhere((MenuCategory c) => c.name == 'Taco');

      final MenuItemOption option = Fixtures.option(
        categoryId: taco.id,
        name: 'Test Salsa',
        price: '15.00',
      );
      await repository.saveOption(option);

      final MenuItem tacoItem = await itemNamed('Taco');
      final List<MenuItemOption> offered = (await repository.loadOptionsForItem(
        tacoItem.id,
      )).valueOrNull!;
      final MenuItemOption loaded = offered.firstWhere(
        (MenuItemOption o) => o.name == 'Test Salsa',
      );

      expect(loaded.scope, MenuOptionScope.category);
      expect(loaded.isGlobal, isFalse);
      expect(loaded.isSizeSpecific, isFalse);
    });
  });

  group('global scoping', () {
    test('reaches every item and every variant', () async {
      await repository.saveOption(
        Fixtures.option(
          name: 'Test Paper Bag',
          optionType: MenuOptionType.condiment,
          price: '3.00',
          displayOrder: 96,
        ),
      );

      final MenuItem sandwich = await itemNamed('Paneer Sandwich');
      expect(
        (await repository.loadOptionsForItem(sandwich.id)).valueOrNull!
            .map((MenuItemOption o) => o.name),
        contains('Test Paper Bag'),
      );

      expect(
        (await optionsForSize('Three Peppers', 'Large'))['Test Paper Bag'],
        Money.parse('3.00'),
      );
    });

    test('the seeded Ketchup reaches a product with no sizes', () async {
      final MenuItem fries = await itemNamed('French Fries');
      final List<MenuItemOption> offered = (await repository.loadOptionsForItem(
        fries.id,
      )).valueOrNull!;

      expect(offered.map((MenuItemOption o) => o.name), <String>['Ketchup']);
      expect(offered.single.price, Money.parse('10'));
    });
  });

  group('precedence when scopes overlap', () {
    test(
      'a variant price overrides a category price of the same name',
      () async {
        final MenuCategory pizzas = (await repository.loadCategories())
            .valueOrNull!
            .firstWhere((MenuCategory c) => c.name == 'Veg Pizza');
        final MenuItemVariant large = await variantOf('Veggie Lovers', 'Large');

        // A general category price, then a narrower one for this exact size.
        await repository.saveOption(
          Fixtures.option(
            categoryId: pizzas.id,
            name: 'Test Olives',
            price: '20.00',
          ),
        );
        await repository.saveOption(
          Fixtures.option(
            variantId: large.id,
            name: 'Test Olives',
            price: '35.00',
          ),
        );

        final List<MenuItemOption> onLarge =
            (await repository.loadOptionsForVariant(large.id)).valueOrNull!;
        final Iterable<MenuItemOption> olives = onLarge.where(
          (MenuItemOption o) => o.name == 'Test Olives',
        );

        // Offered once, at the narrower price. Two prices for one name would leave
        // the counter with no way to choose.
        expect(olives, hasLength(1));
        expect(olives.single.price, Money.parse('35.00'));
        expect(olives.single.scope, MenuOptionScope.variant);

        // A different size still gets the category price.
        final Map<String, Money> onMedium = await optionsForSize(
          'Veggie Lovers',
          'Medium',
        );
        expect(onMedium['Test Olives'], Money.parse('20.00'));
      },
    );

    test('an item price overrides a global price of the same name', () async {
      final MenuItem burger = await itemNamed('Cheese Burger');

      await repository.saveOption(
        Fixtures.option(name: 'Test Dip', price: '20.00'),
      );
      await repository.saveOption(
        Fixtures.option(
          menuItemId: burger.id,
          name: 'Test Dip',
          price: '12.00',
        ),
      );

      final List<MenuItemOption> offered = (await repository.loadOptionsForItem(
        burger.id,
      )).valueOrNull!;
      final Iterable<MenuItemOption> dip = offered.where(
        (MenuItemOption o) => o.name == 'Test Dip',
      );

      expect(dip, hasLength(1));
      expect(dip.single.price, Money.parse('12.00'));
      expect(dip.single.scope, MenuOptionScope.item);

      // Another product still sees the global price.
      final MenuItem taco = await itemNamed('Taco');
      final List<MenuItemOption> onTaco = (await repository.loadOptionsForItem(
        taco.id,
      )).valueOrNull!;
      expect(
        onTaco.firstWhere((MenuItemOption o) => o.name == 'Test Dip').price,
        Money.parse('20.00'),
      );
    });
  });

  group('foreign key integrity', () {
    test('an option cannot reference a variant that does not exist', () async {
      await expectLater(
        database.database.insert(
          SqliteTables.menuItemOptions,
          <String, Object?>{
            'id': 'opt-bad-variant',
            'createdAt': 0,
            'updatedAt': 0,
            'isDeleted': 0,
            'syncState': 'pending',
            'name': 'Test Bad Variant Scope',
            'optionType': 'addOn',
            'pricePaise': 1000,
            'isActive': 1,
            'variantId': 'var-does-not-exist',
          },
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('an option cannot reference a category that does not exist', () async {
      await expectLater(
        database.database.insert(
          SqliteTables.menuItemOptions,
          <String, Object?>{
            'id': 'opt-bad-category',
            'createdAt': 0,
            'updatedAt': 0,
            'isDeleted': 0,
            'syncState': 'pending',
            'name': 'Test Bad Category Scope',
            'optionType': 'addOn',
            'pricePaise': 1000,
            'isActive': 1,
            'categoryId': 'cat-does-not-exist',
          },
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('a repository save with a bad scope fails as a Result', () async {
      // Surfaced as a failure value, not a thrown DatabaseException.
      final result = await repository.saveOption(
        Fixtures.option(variantId: 'var-does-not-exist', name: 'Test Orphan'),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isNotNull);
    });

    test(
      'both scope columns are nullable, so a global option is valid',
      () async {
        final result = await repository.saveOption(
          Fixtures.option(name: 'Test Unscoped', price: '1.00'),
        );

        expect(result.isOk, isTrue);
      },
    );
  });

  group('schema', () {
    test('the scope columns exist and are nullable', () async {
      final List<Map<String, Object?>> columns = await database.database
          .rawQuery('PRAGMA table_info(${SqliteTables.menuItemOptions})');
      final Map<String, Map<String, Object?>> byName =
          <String, Map<String, Object?>>{
            for (final Map<String, Object?> column in columns)
              column['name']! as String: column,
          };

      expect(byName.keys, containsAll(<String>['variantId', 'categoryId']));
      // notnull == 0 means the column accepts NULL, which is what makes an
      // unscoped global option expressible.
      expect(byName['variantId']!['notnull'], 0);
      expect(byName['categoryId']!['notnull'], 0);
    });

    test('the scope columns are indexed', () async {
      final List<Map<String, Object?>>
      indexes = await database.database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
        <Object?>[SqliteTables.menuItemOptions],
      );
      final Set<String> names = indexes
          .map((Map<String, Object?> row) => row['name']! as String)
          .toSet();

      expect(
        names,
        containsAll(<String>['idx_options_variant', 'idx_options_category']),
      );
    });

    test(
      'the unscoped rows from before v4 are retired, not left visible',
      () async {
        // On a fresh database they were never inserted. On an upgraded one they are
        // soft-deleted. Either way nothing readable carries a size in its name.
        final List<Map<String, Object?>> visible = await database.database
            .query(
              SqliteTables.menuItemOptions,
              where: 'isDeleted = 0 AND name LIKE ?',
              whereArgs: <Object?>['%(%'],
            );
        expect(visible, isEmpty);
      },
    );
  });

  group('menu data is unchanged by v4', () {
    test('pizza variant prices still match the printed menu', () async {
      expect(
        (await variantOf('Cheese Pizza', 'Small')).price,
        Money.parse('130'),
      );
      expect(
        (await variantOf('Cheese Pizza', 'Medium')).price,
        Money.parse('250'),
      );
      expect(
        (await variantOf('Cheese Pizza', 'Large')).price,
        Money.parse('400'),
      );
      expect(
        (await variantOf('Tandoori Paneer Pizza', 'Large')).price,
        Money.parse('700'),
      );
    });

    test('item and combo prices are untouched', () async {
      expect((await itemNamed('Potato Burger')).basePrice, Money.parse('50'));
      expect((await itemNamed('Taco')).basePrice, Money.parse('70'));
      expect(
        (await itemNamed('Happy Family Combo')).basePrice,
        Money.parse('1100'),
      );
      expect(
        (await itemNamed('Any 2 Any Burger')).basePrice,
        Money.parse('290'),
      );
      expect(
        (await itemNamed('Combo-3')).description,
        '1 Medium Pizza + 1 Garlic Bread With Dip + 1 Brisko Parcel + '
        '1 Chocolava Cake + Cold Drinks (750ml)',
      );
    });

    test(
      'the menu still holds 12 categories, 64 items and 55 variants',
      () async {
        expect((await repository.loadCategories()).valueOrNull, hasLength(12));
        expect((await repository.loadItems()).valueOrNull, hasLength(64));

        int variants = 0;
        for (final MenuItem item
            in (await repository.loadItems()).valueOrNull!) {
          variants += (await repository.loadVariants(item.id))
              .valueOrNull!
              .length;
        }
        expect(variants, 55);
      },
    );
  });

  group('idempotency', () {
    Future<int> optionCount() async {
      final List<Map<String, Object?>> rows = await database.database.rawQuery(
        'SELECT COUNT(*) AS c FROM ${SqliteTables.menuItemOptions}',
      );
      return rows.first['c']! as int;
    }

    test('re-running the option seed creates no duplicates', () async {
      final int before = await optionCount();

      await M004ScopedMenuOptions.seedScopedOptions(database.database);
      await M004ScopedMenuOptions.seedScopedOptions(database.database);

      expect(await optionCount(), before);
      expect((await repository.loadAllOptions()).valueOrNull, hasLength(171));
    });

    test('re-seeding does not overwrite an operator price change', () async {
      final MenuItemVariant medium = await variantOf('Achari Pizza', 'Medium');
      final List<MenuItemOption> options =
          (await repository.loadOptionsForVariant(medium.id)).valueOrNull!;
      final MenuItemOption cheese = options.firstWhere(
        (MenuItemOption o) => o.name == 'Extra Cheese',
      );
      expect(cheese.price, Money.parse('70'));

      expect(
        (await repository.saveOption(
          cheese.copyWith(
            price: Money.parse('85'),
            updatedAt: DateTime.now().toUtc(),
          ),
        )).isOk,
        isTrue,
      );

      await M004ScopedMenuOptions.seedScopedOptions(database.database);

      final Map<String, Money> reloaded = await optionsForSize(
        'Achari Pizza',
        'Medium',
      );
      expect(reloaded['Extra Cheese'], Money.parse('85'));
      // Another pizza keeps the printed price, so the edit stayed local.
      expect(
        (await optionsForSize('Farmfresh', 'Medium'))['Extra Cheese'],
        Money.parse('70'),
      );
    });

    test(
      're-seeding does not resurrect an option the operator removed',
      () async {
        final MenuItemVariant small = await variantOf('Garden Fresh', 'Small');
        final MenuItemOption crust =
            (await repository.loadOptionsForVariant(small.id)).valueOrNull!
                .firstWhere((MenuItemOption o) => o.name == 'Thin Crust');

        await repository.saveOption(
          crust.copyWith(isDeleted: true, updatedAt: DateTime.now().toUtc()),
        );

        await M004ScopedMenuOptions.seedScopedOptions(database.database);

        final Map<String, Money> options = await optionsForSize(
          'Garden Fresh',
          'Small',
        );
        expect(options.containsKey('Thin Crust'), isFalse);
        // Other pizzas are unaffected.
        expect(
          (await optionsForSize('Farmfresh', 'Small'))['Thin Crust'],
          Money.parse('30'),
        );
      },
    );

    test('seeded options are not queued for upload', () async {
      final List<Map<String, Object?>> rows = await database.database.query(
        SqliteTables.menuItemOptions,
        where: 'syncState != ? AND isDeleted = 0',
        whereArgs: <Object?>['synced'],
      );
      expect(rows, isEmpty);
    });
  });
}
