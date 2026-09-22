import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/seed/menu_seed_data.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_type.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_scope.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_database.dart';

/// Verifies the seeded menu against the outlet's printed menu.
///
/// The expected values below are transcribed from the printed menu a second time,
/// independently of `MenuSeedData`, so a mistyped price has to be made twice in the
/// same way to slip through. Prices are asserted through `Money`, so a value stored
/// in the wrong unit fails.
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

  Future<int> countRows(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS c FROM $table',
    );
    return rows.first['c']! as int;
  }

  Future<MenuItem> itemNamed(String name) async {
    final List<MenuItem> items = (await repository.loadItems()).valueOrNull!;
    return items.firstWhere(
      (MenuItem item) => item.name == name,
      orElse: () => throw StateError('No seeded item named "$name"'),
    );
  }

  Future<Map<String, Money>> variantPrices(String itemName) async {
    final MenuItem item = await itemNamed(itemName);
    final List<MenuItemVariant> variants = (await repository.loadVariants(
      item.id,
    )).valueOrNull!;
    return <String, Money>{
      for (final MenuItemVariant variant in variants)
        variant.name: variant.price,
    };
  }

  group('categories', () {
    test('all twelve printed sections are seeded, in printed order', () async {
      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;

      expect(categories.map((MenuCategory c) => c.name), <String>[
        'Veg Pizza',
        'Burger',
        'Wraps',
        'Taco',
        'Sandwich',
        'Coffee',
        'Shakes / Mocktails',
        'Family Combos',
        'Twin Treat Pizza Combo',
        'Burger Combo',
        'Side Orders',
        'Cold Drinks',
      ]);
    });

    test('categories are active and use deterministic ids', () async {
      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;

      expect(categories.every((MenuCategory c) => c.isActive), isTrue);
      expect(categories.every((MenuCategory c) => !c.isDeleted), isTrue);
      expect(categories.first.id, 'cat-veg-pizza');
      expect(categories.last.id, 'cat-cold-drinks');
    });
  });

  group('pizza size pricing', () {
    // Small / Medium / Large, exactly as printed in the Veg Pizza panel.
    const Map<String, List<String>> printed = <String, List<String>>{
      // Simply Veg
      'Cheese Pizza': <String>['130', '250', '400'],
      'Cheese & Tomato': <String>['200', '310', '480'],
      'Cheese & Onion': <String>['200', '310', '480'],
      // Veg Delight
      'Double Cheese Pizza': <String>['150', '310', '480'],
      'Garden Fresh': <String>['240', '370', '560'],
      'Cheese & Paneer': <String>['240', '370', '560'],
      'Cheese & Corn': <String>['240', '370', '560'],
      // Veg Treat
      'Farmfresh': <String>['240', '370', '560'],
      'Country Feast': <String>['240', '370', '560'],
      'Spicy Tango Pizza': <String>['240', '370', '560'],
      'Wonder Pizza': <String>['240', '370', '560'],
      // Veg Special
      'Spicy Paneer': <String>['270', '460', '700'],
      'Three Peppers': <String>['270', '460', '700'],
      'Delicious Pizza': <String>['270', '460', '700'],
      'Veggie Lovers': <String>['270', '460', '700'],
      'Achari Pizza': <String>['270', '460', '700'],
      'Tandoori Paneer Pizza': <String>['270', '460', '700'],
    };

    test('seventeen pizzas are seeded', () async {
      final MenuCategory pizzaCategory = (await repository.loadCategories())
          .valueOrNull!
          .firstWhere((MenuCategory c) => c.name == 'Veg Pizza');

      final List<MenuItem> pizzas = (await repository.loadItems(
        categoryId: pizzaCategory.id,
      )).valueOrNull!;

      expect(pizzas, hasLength(17));
      expect(printed, hasLength(17));
    });

    for (final MapEntry<String, List<String>> entry in printed.entries) {
      test('${entry.key} is priced ${entry.value.join(" / ")}', () async {
        final Map<String, Money> prices = await variantPrices(entry.key);

        expect(prices.keys, <String>['Small', 'Medium', 'Large']);
        expect(prices['Small'], Money.parse(entry.value[0]));
        expect(prices['Medium'], Money.parse(entry.value[1]));
        expect(prices['Large'], Money.parse(entry.value[2]));

        // The base price is the smallest printed size.
        final MenuItem item = await itemNamed(entry.key);
        expect(item.basePrice, Money.parse(entry.value[0]));
      });
    }

    test('sizes are returned in printed order, cheapest first', () async {
      final MenuItem cheese = await itemNamed('Cheese Pizza');
      final List<MenuItemVariant> variants = (await repository.loadVariants(
        cheese.id,
      )).valueOrNull!;

      expect(variants.map((MenuItemVariant v) => v.name), <String>[
        'Small',
        'Medium',
        'Large',
      ]);
      expect(variants[0].price < variants[1].price, isTrue);
      expect(variants[1].price < variants[2].price, isTrue);
    });

    test('pizzas keep their printed topping descriptions', () async {
      expect(
        (await itemNamed('Farmfresh')).description,
        'Onion, Capsicum, Tomato with Grilled Mushroom',
      );
      expect(
        (await itemNamed('Cheese Pizza')).description,
        'Single Cheese Topped',
      );
      // Printed with no topping line.
      expect((await itemNamed('Cheese & Paneer')).description, isNull);
    });

    test('pizzas are ordered by printed sub-section', () async {
      final MenuCategory pizzaCategory = (await repository.loadCategories())
          .valueOrNull!
          .firstWhere((MenuCategory c) => c.name == 'Veg Pizza');
      final List<MenuItem> pizzas = (await repository.loadItems(
        categoryId: pizzaCategory.id,
      )).valueOrNull!;

      // Simply Veg first, Veg Special last.
      expect(pizzas.first.name, 'Cheese Pizza');
      expect(pizzas.last.name, 'Tandoori Paneer Pizza');
    });
  });

  group('item prices by category', () {
    // Name to printed price, for every product that has a single price.
    const Map<String, Map<String, String>> printed =
        <String, Map<String, String>>{
          'Burger': <String, String>{
            'Potato Burger': '50',
            'Cheese Burger': '60',
            'Onion & Capsicum Burger': '80',
            'Corn Topping Burger': '80',
            'Tandoori Sauce Burger': '80',
            'Paneer Burger': '100',
            'Achari Paneer Burger': '110',
          },
          'Wraps': <String, String>{
            'Veggies Wrap': '80',
            'Paneer Wrap': '100',
            'Paneer Makhani Wrap': '100',
          },
          'Taco': <String, String>{'Taco': '70'},
          'Sandwich': <String, String>{
            'Veggie Sandwich': '60',
            'Cheese Grilled Sandwich': '70',
            'Veggie Corn Sandwich': '80',
            'Paneer Sandwich': '80',
            'Makhani Paneer Sandwich': '90',
            'Achari Paneer Sandwich': '90',
          },
          'Coffee': <String, String>{'Hot Coffee': '30'},
          'Shakes / Mocktails': <String, String>{
            'Mint Mojito': '80',
            'Spicy Mango': '80',
            'Cold Coffee': '120',
            'Fruit Shake': '120',
            'Strawberry Shake': '120',
            'Kit-Kat Shake': '120',
            'Chocolate Shake': '120',
            'Oreo Shake': '120',
          },
          'Side Orders': <String, String>{
            'Brisko Parcel': '50',
            'French Fries': '70',
            'Peri-Peri French Fries': '90',
            'Cheese Garlic Bread': '90',
            'Stuffed Garlic Bread': '120',
            'Veg Red Sauce Pasta': '110',
            'Veg White Sauce Pasta': '120',
            'Mix Sauce Pasta': '130',
            'Makhani Sauce Pasta': '140',
            'Veg Calzone Pocket': '140',
            'Chocolava Cake': '60',
            'Cheese Dip': '20',
            'Jalapeno Dip': '20',
          },
        };

    for (final MapEntry<String, Map<String, String>> section
        in printed.entries) {
      group(section.key, () {
        test('holds exactly the printed products', () async {
          final MenuCategory category = (await repository.loadCategories())
              .valueOrNull!
              .firstWhere((MenuCategory c) => c.name == section.key);
          final List<MenuItem> items = (await repository.loadItems(
            categoryId: category.id,
          )).valueOrNull!;

          expect(
            items.map((MenuItem i) => i.name).toSet(),
            section.value.keys.toSet(),
          );
        });

        for (final MapEntry<String, String> entry in section.value.entries) {
          test('${entry.key} is ${entry.value}', () async {
            final MenuItem item = await itemNamed(entry.key);
            expect(item.basePrice, Money.parse(entry.value));
            // A single-price product has no size variants.
            expect(
              (await repository.loadVariants(item.id)).valueOrNull,
              isEmpty,
            );
          });
        }
      });
    }
  });

  group('cold drinks', () {
    test('one product carries a variant per printed bottle size', () async {
      final Map<String, Money> prices = await variantPrices('Cold Drinks');

      expect(prices, <String, Money>{
        '250ml': Money.parse('30'),
        '500ml': Money.parse('50'),
        '750ml': Money.parse('80'),
        '1Ltr': Money.parse('110'),
      });
    });

    test('is not duplicated into Shakes / Mocktails', () async {
      // The shakes panel cross-references cold drinks without a price. Seeding it
      // there too would create a second product with no basis on the menu.
      final MenuCategory shakes = (await repository.loadCategories())
          .valueOrNull!
          .firstWhere((MenuCategory c) => c.name == 'Shakes / Mocktails');
      final List<MenuItem> items = (await repository.loadItems(
        categoryId: shakes.id,
      )).valueOrNull!;

      expect(items.map((MenuItem i) => i.name), isNot(contains('Cold Drinks')));
    });
  });

  group('combos', () {
    test('Family Combos carry their printed price and contents', () async {
      const Map<String, String> printedPrices = <String, String>{
        'Combo-1': '220',
        'Combo-2': '400',
        'Combo-3': '650',
        'Happy Family Combo': '1100',
      };

      for (final MapEntry<String, String> entry in printedPrices.entries) {
        final MenuItem combo = await itemNamed(entry.key);
        expect(combo.basePrice, Money.parse(entry.value));
        // The contents line is what makes a combo intelligible at the counter.
        expect(combo.description, isNotNull);
        expect(combo.description, isNotEmpty);
      }

      expect(
        (await itemNamed('Combo-1')).description,
        'Double Topping Pizza With Extra Cheese + Cheese Burger + '
        'Cold Drinks 250ml',
      );
      expect(
        (await itemNamed('Happy Family Combo')).description,
        '2 Medium Pizza + 1 Garlic Bread With Dip + 1 Brisko Parcel + '
        '1 French Fries + 1 Chocolava Cake + Pasta + Cold Drinks (1Ltr)',
      );
    });

    test('Twin Treat Pizza Combo holds both printed offers', () async {
      expect(
        (await itemNamed('Any 2 Medium Pizzas')).basePrice,
        Money.parse('700'),
      );
      expect(
        (await itemNamed('Any 2 Large Pizzas')).basePrice,
        Money.parse('1000'),
      );
    });

    test('Burger Combo holds the printed offer', () async {
      expect(
        (await itemNamed('Any 2 Any Burger')).basePrice,
        Money.parse('290'),
      );
    });

    test(
      'seven combo products exist across the three combo sections',
      () async {
        final List<MenuCategory> categories =
            (await repository.loadCategories()).valueOrNull!;
        int total = 0;
        for (final String name in <String>[
          'Family Combos',
          'Twin Treat Pizza Combo',
          'Burger Combo',
        ]) {
          final MenuCategory category = categories.firstWhere(
            (MenuCategory c) => c.name == name,
          );
          total += (await repository.loadItems(categoryId: category.id))
              .valueOrNull!
              .length;
        }
        expect(total, 9);
      },
    );
  });

  group('options', () {
    test('names carry the customisation only, with no size', () async {
      // Scope now lives in variantId, so the name is clean. Any screen that had to
      // read a size out of a name would break the first time one was renamed.
      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;

      expect(options.map((MenuItemOption o) => o.name).toSet(), <String>{
        'Thin Crust',
        'Cheese Burst',
        'Extra Cheese',
        'Extra Toppings',
        'Ketchup',
      });
      expect(
        options.every((MenuItemOption o) => !o.name.contains('(')),
        isTrue,
        reason: 'no visible option may encode a size in its name',
      );
    });

    test('no option is seeded at zero', () async {
      // A free add-on would be a fabricated business rule that gives food away.
      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;

      expect(options, isNotEmpty);
      expect(options.every((MenuItemOption o) => o.price.isPositive), isTrue);
    });

    test('options are classified by kind', () async {
      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;
      final Map<String, MenuOptionType> byName = <String, MenuOptionType>{
        for (final MenuItemOption option in options)
          option.name: option.optionType,
      };

      expect(byName['Thin Crust'], MenuOptionType.crust);
      expect(byName['Cheese Burst'], MenuOptionType.crust);
      expect(byName['Extra Cheese'], MenuOptionType.addOn);
      expect(byName['Extra Toppings'], MenuOptionType.addOn);
      expect(byName['Ketchup'], MenuOptionType.condiment);
    });

    test('there are no global options', () async {
      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;
      final Iterable<MenuItemOption> global = options.where(
        (MenuItemOption o) => o.isGlobal,
      );

      expect(global, isEmpty);
    });

    test('options are scoped to a variant or category', () async {
      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;
      final Iterable<MenuItemOption> variantScoped = options.where(
        (MenuItemOption o) => o.scope == MenuOptionScope.variant,
      );
      final Iterable<MenuItemOption> categoryScoped = options.where(
        (MenuItemOption o) => o.scope == MenuOptionScope.category,
      );

      // Seventeen pizzas x ten priced option cells.
      expect(variantScoped, hasLength(170));
      // 9 food categories have Ketchup
      expect(categoryScoped, hasLength(9));
      expect(
        variantScoped.every((MenuItemOption o) => o.isSizeSpecific),
        isTrue,
      );
      expect(
        categoryScoped.every((MenuItemOption o) => o.categoryId != null),
        isTrue,
      );
    });

    test('asking by item returns only size-independent options', () async {
      // A size-dependent price is undefined without a size, so it is withheld
      // rather than returned at some arbitrary size's price.
      final MenuItem pizza = await itemNamed('Farmfresh');
      final List<MenuItemOption> offered = (await repository.loadOptionsForItem(
        pizza.id,
      )).valueOrNull!;

      expect(offered.map((MenuItemOption o) => o.name), <String>['Ketchup']);
    });
  });

  group('food classification', () {
    test('every product is vegetarian, as the masthead states', () async {
      // The menu is marked PURE VEG, so this is read from the menu, not assumed.
      final List<MenuItem> items = (await repository.loadItems()).valueOrNull!;

      expect(items, isNotEmpty);
      expect(
        items.every((MenuItem i) => i.itemType == MenuItemType.veg),
        isTrue,
      );
      expect(
        items.any((MenuItem i) => i.itemType == MenuItemType.nonVeg),
        isFalse,
      );
      expect(
        items.any((MenuItem i) => i.itemType == MenuItemType.egg),
        isFalse,
      );
    });
  });

  group('totals', () {
    test('the seed loads the whole menu', () async {
      expect(MenuSeedData.categories, hasLength(12));
      expect(MenuSeedData.items, hasLength(66));
      // 17 pizzas x 3 sizes, plus 4 cold drink sizes.
      expect(MenuSeedData.variants, hasLength(55));
      // 17 pizzas x 10 priced option cells, plus the 9 scoped ketchup options.
      expect(MenuSeedData.options, hasLength(179));
      expect(MenuSeedData.hasProducts, isTrue);

      expect(await countRows(SqliteTables.categories), 12);
      expect(await countRows(SqliteTables.menuItems), 66);
      expect(await countRows(SqliteTables.menuItemVariants), 55);
      // A fresh database holds only the scoped rows. An upgraded one also carries
      // the ten retired rows, soft-deleted and invisible to every read.
      expect(await countRows(SqliteTables.menuItemOptions), 179);
      expect((await repository.loadAllOptions()).valueOrNull, hasLength(179));
    });

    test('every item belongs to a seeded category', () async {
      // A dangling categoryId would have failed the foreign key on insert, but
      // this also catches a typo that happens to match another category.
      final Set<String> categorySlugs = MenuSeedData.categories
          .map((SeedCategory c) => c.slug)
          .toSet();

      for (final SeedMenuItem item in MenuSeedData.items) {
        expect(
          categorySlugs,
          contains(item.categorySlug),
          reason: '${item.name} points at an unknown category',
        );
      }
    });

    test('every variant belongs to a seeded item', () async {
      final Set<String> itemSlugs = MenuSeedData.items
          .map((SeedMenuItem i) => i.slug)
          .toSet();

      for (final SeedVariant variant in MenuSeedData.variants) {
        expect(
          itemSlugs,
          contains(variant.itemSlug),
          reason: '${variant.name} points at an unknown item',
        );
      }
    });

    test('slugs are unique, so no seed row overwrites another', () async {
      final List<String> itemSlugs = MenuSeedData.items
          .map((SeedMenuItem i) => i.slug)
          .toList();
      expect(itemSlugs.toSet(), hasLength(itemSlugs.length));

      final List<String> variantIds = MenuSeedData.variants
          .map((SeedVariant v) => v.id)
          .toList();
      expect(variantIds.toSet(), hasLength(variantIds.length));

      final List<String> optionSlugs = MenuSeedData.options
          .map((SeedOption o) => o.slug)
          .toList();
      expect(optionSlugs.toSet(), hasLength(optionSlugs.length));
    });

    test('every product is active and available', () async {
      final List<MenuItem> items = (await repository.loadItems()).valueOrNull!;

      expect(items.every((MenuItem i) => i.isActive), isTrue);
      expect(items.every((MenuItem i) => i.isAvailable), isTrue);
      expect(items.every((MenuItem i) => i.isSellable), isTrue);
    });
  });

  group('idempotency', () {
    test('running the seed again creates no duplicates', () async {
      final int categories = await countRows(SqliteTables.categories);
      final int items = await countRows(SqliteTables.menuItems);
      final int variants = await countRows(SqliteTables.menuItemVariants);
      final int options = await countRows(SqliteTables.menuItemOptions);

      // Twice more, so idempotency is not a one-shot accident. A fresh install
      // has already run it twice, at version 2 and version 3.
      await M002SeedMenu.seed(database.database);
      await M002SeedMenu.seed(database.database);

      expect(await countRows(SqliteTables.categories), categories);
      expect(await countRows(SqliteTables.menuItems), items);
      expect(await countRows(SqliteTables.menuItemVariants), variants);
      expect(await countRows(SqliteTables.menuItemOptions), options);
    });

    test('re-seeding does not overwrite an operator price change', () async {
      final MenuItem burger = await itemNamed('Cheese Burger');
      expect(burger.basePrice, Money.parse('60'));

      final MenuItem repriced = burger.copyWith(
        name: 'Cheese Burger (Operator Edit)',
        basePrice: Money.parse('75'),
        updatedAt: DateTime.now().toUtc(),
      );
      expect((await repository.saveItem(repriced)).isOk, isTrue);

      await M002SeedMenu.seed(database.database);

      final MenuItem reloaded = (await repository.findItem(burger.id))
          .valueOrNull!;
      expect(reloaded.name, 'Cheese Burger (Operator Edit)');
      expect(reloaded.basePrice, Money.parse('75'));
    });

    test(
      're-seeding does not overwrite an operator variant price change',
      () async {
        final MenuItem pizza = await itemNamed('Cheese Pizza');
        final List<MenuItemVariant> variants = (await repository.loadVariants(
          pizza.id,
        )).valueOrNull!;
        final MenuItemVariant medium = variants.firstWhere(
          (MenuItemVariant v) => v.name == 'Medium',
        );

        expect(
          (await repository.saveVariant(
            medium.copyWith(
              price: Money.parse('275'),
              updatedAt: DateTime.now().toUtc(),
            ),
          )).isOk,
          isTrue,
        );

        await M002SeedMenu.seed(database.database);

        final Map<String, Money> prices = await variantPrices('Cheese Pizza');
        expect(prices['Medium'], Money.parse('275'));
      },
    );

    test(
      're-seeding does not resurrect an item the operator removed',
      () async {
        final MenuItem discontinued = await itemNamed('Jalapeno Dip');
        expect((await repository.deleteItem(discontinued.id)).isOk, isTrue);

        await M002SeedMenu.seed(database.database);

        expect(
          (await repository.findItem(discontinued.id)).valueOrNull,
          isNull,
        );
      },
    );

    test('seed rows use stable ids derived from their slug', () async {
      expect((await itemNamed('Cheese Pizza')).id, 'item-cheese-pizza');
      expect(
        (await itemNamed('Happy Family Combo')).id,
        'item-happy-family-combo',
      );

      final Map<String, Money> prices = await variantPrices('Cheese Pizza');
      expect(prices, isNotEmpty);

      final List<MenuItemVariant> variants = (await repository.loadVariants(
        (await itemNamed('Cheese Pizza')).id,
      )).valueOrNull!;
      expect(
        variants.firstWhere((MenuItemVariant v) => v.name == 'Medium').id,
        'var-cheese-pizza-medium',
      );
    });

    test('seeded reference data is not queued for upload', () async {
      // The menu is identical on every terminal, so pushing it would be noise.
      for (final String table in <String>[
        SqliteTables.categories,
        SqliteTables.menuItems,
        SqliteTables.menuItemVariants,
        SqliteTables.menuItemOptions,
      ]) {
        final List<Map<String, Object?>> rows = await database.database.query(
          table,
          where: 'syncState != ?',
          whereArgs: <Object?>['synced'],
        );
        expect(rows, isEmpty, reason: '$table should be marked synced');
      }
    });
  });

  group('values not readable from the menu', () {
    test('the outstanding list names only genuine absences', () {
      // Both entries are prices the menu does not print, not illegible text.
      expect(MenuSeedData.pendingFromMenuImage, hasLength(2));
      expect(
        MenuSeedData.pendingFromMenuImage.join(' '),
        allOf(contains('Thin Crust'), contains('Cheese Burst')),
      );
    });
  });
}
