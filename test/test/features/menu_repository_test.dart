import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository repository;
  late MenuCategory category;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    repository = SqliteMenuRepository(database: database);

    category = Fixtures.category(name: 'Test Section');
    await repository.saveCategory(category);
  });

  tearDown(() async {
    await database.close();
  });

  group('categories', () {
    test('can be saved and loaded', () async {
      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;
      expect(
        categories.where((MenuCategory c) => c.id == category.id),
        hasLength(1),
      );
    });

    test('an inactive category is excluded from billing', () async {
      await repository.saveCategory(
        category.copyWith(isActive: false, updatedAt: DateTime.now().toUtc()),
      );

      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;
      expect(
        categories.map((MenuCategory c) => c.id),
        isNot(contains(category.id)),
      );
    });
  });

  group('menu items', () {
    test('can be saved and loaded, preserving the exact price', () async {
      final MenuItem item = Fixtures.menuItem(
        categoryId: category.id,
        name: 'Test Pizza',
        basePrice: '249.50',
      );
      expect((await repository.saveItem(item)).isOk, isTrue);

      final List<MenuItem> items = (await repository.loadItems(
        categoryId: category.id,
      )).valueOrNull!;

      expect(items, hasLength(1));
      expect(items.first.name, 'Test Pizza');
      expect(items.first.basePrice, Money.parse('249.50'));
      expect(items.first.basePrice.paise, 24950);
    });

    test('are filtered by category', () async {
      final MenuCategory other = Fixtures.category(name: 'Other Section');
      await repository.saveCategory(other);

      await repository.saveItem(
        Fixtures.menuItem(categoryId: category.id, name: 'In Section'),
      );
      await repository.saveItem(
        Fixtures.menuItem(categoryId: other.id, name: 'In Other'),
      );

      final List<MenuItem> inSection = (await repository.loadItems(
        categoryId: category.id,
      )).valueOrNull!;
      expect(inSection.map((MenuItem i) => i.name), <String>['In Section']);

      final List<MenuItem> inOther = (await repository.loadItems(
        categoryId: other.id,
      )).valueOrNull!;
      expect(inOther.map((MenuItem i) => i.name), <String>['In Other']);

      // Unfiltered returns both, alongside the real seeded menu. Asserted by
      // containment rather than by count, so adding a product to the seed does
      // not break an unrelated test.
      final Iterable<String> all = (await repository.loadItems()).valueOrNull!
          .map((MenuItem i) => i.name);
      expect(all, containsAll(<String>['In Section', 'In Other']));
    });

    test('an unavailable item is still loaded but is not sellable', () async {
      // Out of stock is a display state, not a reason to hide history.
      final MenuItem item = Fixtures.menuItem(
        categoryId: category.id,
        isAvailable: false,
      );
      await repository.saveItem(item);

      final MenuItem? loaded = (await repository.findItem(item.id)).valueOrNull;
      expect(loaded, isNotNull);
      expect(loaded!.isAvailable, isFalse);
      expect(loaded.isSellable, isFalse);
    });
  });

  group('variants', () {
    test('size pricing loads in display order', () async {
      final MenuItem pizza = Fixtures.menuItem(
        categoryId: category.id,
        name: 'Test Pizza',
      );
      await repository.saveItem(pizza);

      // Saved out of order on purpose.
      await repository.saveVariant(
        Fixtures.variant(
          menuItemId: pizza.id,
          name: 'Large',
          price: '449.00',
          displayOrder: 3,
        ),
      );
      await repository.saveVariant(
        Fixtures.variant(
          menuItemId: pizza.id,
          name: 'Small',
          price: '199.00',
          displayOrder: 1,
        ),
      );
      await repository.saveVariant(
        Fixtures.variant(
          menuItemId: pizza.id,
          name: 'Medium',
          price: '299.00',
          displayOrder: 2,
        ),
      );

      final List<MenuItemVariant> variants = (await repository.loadVariants(
        pizza.id,
      )).valueOrNull!;

      expect(variants.map((MenuItemVariant v) => v.name), <String>[
        'Small',
        'Medium',
        'Large',
      ]);
      expect(variants[1].price, Money.parse('299.00'));
    });

    test('an item without sizes has no variants', () async {
      final MenuItem drink = Fixtures.menuItem(
        categoryId: category.id,
        name: 'Test Drink',
      );
      await repository.saveItem(drink);

      expect((await repository.loadVariants(drink.id)).valueOrNull, isEmpty);
    });
  });

  group('options', () {
    test('an item receives both its own options and the global ones', () async {
      final MenuItem pizza = Fixtures.menuItem(categoryId: category.id);
      final MenuItem burger = Fixtures.menuItem(
        categoryId: category.id,
        name: 'Test Burger',
      );
      await repository.saveItem(pizza);
      await repository.saveItem(burger);

      // Global: applies to everything, stored once rather than per item.
      await repository.saveOption(
        Fixtures.option(
          name: 'Test Ketchup',
          optionType: MenuOptionType.condiment,
          price: '10.00',
        ),
      );
      // Scoped to the pizza only.
      await repository.saveOption(
        Fixtures.option(
          menuItemId: pizza.id,
          name: 'Test Thin Crust',
          optionType: MenuOptionType.crust,
          price: '0.00',
        ),
      );

      final List<MenuItemOption> pizzaOptions =
          (await repository.loadOptionsForItem(pizza.id)).valueOrNull!;
      final List<MenuItemOption> burgerOptions =
          (await repository.loadOptionsForItem(burger.id)).valueOrNull!;

      expect(
        pizzaOptions.map((MenuItemOption o) => o.name),
        containsAll(<String>['Test Ketchup', 'Test Thin Crust']),
      );
      // The burger sees the global option but not the pizza-scoped one. Asserted
      // by presence and absence rather than as an exact list, because the real
      // seeded menu contributes its own global options to both results.
      expect(
        burgerOptions.map((MenuItemOption o) => o.name),
        contains('Test Ketchup'),
      );
      expect(
        burgerOptions.map((MenuItemOption o) => o.name),
        isNot(contains('Test Thin Crust')),
      );
    });

    test('a global option reports itself as global', () async {
      final MenuItemOption global = Fixtures.option(name: 'Test Global');
      await repository.saveOption(global);

      final List<MenuItemOption> options =
          (await repository.loadAllOptions()).valueOrNull!;
      final MenuItemOption loaded = options.firstWhere(
        (MenuItemOption o) => o.id == global.id,
      );

      expect(loaded.isGlobal, isTrue);
      expect(loaded.menuItemId, isNull);
    });
  });

  group('soft delete', () {
    test('a deleted item disappears from reads but the row survives', () async {
      final MenuItem item = Fixtures.menuItem(categoryId: category.id);
      await repository.saveItem(item);

      expect((await repository.deleteItem(item.id)).isOk, isTrue);

      expect((await repository.findItem(item.id)).valueOrNull, isNull);
      // Absent from the list, which also holds the real seeded menu.
      expect(
        (await repository.loadItems()).valueOrNull!.map((MenuItem i) => i.id),
        isNot(contains(item.id)),
      );

      // The row is still physically present, so the deletion can be transmitted
      // to a backend later.
      final List<Map<String, Object?>> raw = await database.database.query(
        'menu_items',
        where: 'id = ?',
        whereArgs: <Object?>[item.id],
      );
      expect(raw, hasLength(1));
      expect(raw.first['isDeleted'], 1);
      expect(raw.first['syncState'], 'pending');
    });

    test('deleting a category hides it without touching its items', () async {
      final MenuItem item = Fixtures.menuItem(categoryId: category.id);
      await repository.saveItem(item);

      await repository.deleteCategory(category.id);

      final List<MenuCategory> categories =
          (await repository.loadCategories()).valueOrNull!;
      expect(
        categories.map((MenuCategory c) => c.id),
        isNot(contains(category.id)),
      );

      // The item is untouched: history must not vanish because a section was
      // tidied up.
      expect((await repository.findItem(item.id)).valueOrNull, isNotNull);
    });
  });

  group('watchCategories', () {
    test('emits again when a category is saved', () async {
      final Stream<List<MenuCategory>> stream = repository.watchCategories();
      final Future<List<List<MenuCategory>>> collected = stream
          .take(2)
          .toList();

      // Give the initial emission a turn before mutating.
      await Future<void>.delayed(Duration.zero);
      await repository.saveCategory(Fixtures.category(name: 'Added Later'));

      final List<List<MenuCategory>> emissions = await collected;
      expect(emissions, hasLength(2));
      expect(emissions.last.length, greaterThan(emissions.first.length - 1));
    });
  });
}
