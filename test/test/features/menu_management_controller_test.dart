import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_type.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_scope.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:brisko_billing/features/menu/presentation/controllers/menu_management_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_database.dart';

/// Drives the menu-management controller over the real SQLite repository.
///
/// The controller re-reads after every write, so each test asserts against the state
/// the owner would see on the screen, not against a value it passed in. The billing
/// view methods on the same repository are used to prove that a change is or is not
/// reflected at the counter.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository repository;
  late MenuManagementController controller;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    repository = SqliteMenuRepository(database: database);
    controller = MenuManagementController(menuRepository: repository);
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  /// The controller's view of one category by name, after its last reload.
  MenuCategory categoryNamed(String name) =>
      controller.categories.firstWhere((MenuCategory c) => c.name == name);

  MenuItem itemNamed(String name) =>
      controller.items.firstWhere((MenuItem i) => i.name == name);

  group('categories', () {
    test('create adds a category shown in management and billing', () async {
      final bool created = await controller.createCategory('Desserts');
      expect(created, isTrue);

      expect(
        controller.categories.map((MenuCategory c) => c.name),
        contains('Desserts'),
      );

      // Active by default, so billing sees it too.
      final List<MenuCategory> billing =
          (await repository.loadCategories()).valueOrNull!;
      expect(billing.map((MenuCategory c) => c.name), contains('Desserts'));
    });

    test('rename keeps the id and changes only the name', () async {
      await controller.createCategory('Deserts');
      final MenuCategory before = categoryNamed('Deserts');

      final bool renamed = await controller.renameCategory(before, 'Desserts');
      expect(renamed, isTrue);

      final MenuCategory after = categoryNamed('Desserts');
      expect(after.id, before.id);
      expect(
        controller.categories.map((MenuCategory c) => c.name),
        isNot(contains('Deserts')),
      );
    });

    test(
      'deactivating hides a category from billing but not management',
      () async {
        await controller.createCategory('Seasonal');
        final MenuCategory category = categoryNamed('Seasonal');

        await controller.setCategoryActive(category, isActive: false);

        // Still listed for management, marked inactive.
        final MenuCategory managed = categoryNamed('Seasonal');
        expect(managed.isActive, isFalse);

        // Gone from the billing view.
        final List<MenuCategory> billing =
            (await repository.loadCategories()).valueOrNull!;
        expect(
          billing.map((MenuCategory c) => c.name),
          isNot(contains('Seasonal')),
        );
      },
    );

    test('reordering swaps display order with the neighbour', () async {
      await controller.createCategory('Alpha');
      await controller.createCategory('Beta');
      final MenuCategory beta = categoryNamed('Beta');
      final MenuCategory alpha = categoryNamed('Alpha');
      expect(beta.displayOrder, greaterThan(alpha.displayOrder));

      await controller.moveCategoryUp(beta);

      final MenuCategory movedBeta = categoryNamed('Beta');
      final MenuCategory movedAlpha = categoryNamed('Alpha');
      expect(movedBeta.displayOrder, lessThan(movedAlpha.displayOrder));
    });
  });

  group('items', () {
    late String categoryId;

    setUp(() async {
      await controller.createCategory('Test Section');
      categoryId = categoryNamed('Test Section').id;
    });

    test('create adds an item at the given price', () async {
      final bool created = await controller.createItem(
        categoryId: categoryId,
        name: 'Garlic Bread',
        basePrice: Money.parse('120.50'),
        itemType: MenuItemType.veg,
        description: 'Toasted with butter',
      );
      expect(created, isTrue);

      final MenuItem item = itemNamed('Garlic Bread');
      expect(item.basePrice, Money.parse('120.50'));
      expect(item.basePrice.paise, 12050);
      expect(item.description, 'Toasted with butter');
      expect(item.categoryId, categoryId);
      expect(item.isSellable, isTrue);
    });

    test('edit changes fields while keeping the same id', () async {
      await controller.createItem(
        categoryId: categoryId,
        name: 'Paneer Roll',
        basePrice: Money.parse('90.00'),
        itemType: MenuItemType.veg,
      );
      final MenuItem before = itemNamed('Paneer Roll');

      final bool updated = await controller.updateItem(
        before,
        name: 'Paneer Kathi Roll',
        basePrice: Money.parse('110.00'),
        itemType: MenuItemType.veg,
        categoryId: categoryId,
        description: 'Now with mint chutney',
      );
      expect(updated, isTrue);

      final MenuItem after = itemNamed('Paneer Kathi Roll');
      expect(after.id, before.id, reason: 'id must be stable across an edit');
      expect(after.basePrice, Money.parse('110.00'));
      expect(after.description, 'Now with mint chutney');
    });

    test(
      'deactivating hides an item from billing but keeps it for management',
      () async {
        await controller.createItem(
          categoryId: categoryId,
          name: 'Retired Special',
          basePrice: Money.parse('99.00'),
          itemType: MenuItemType.veg,
        );
        final MenuItem item = itemNamed('Retired Special');

        await controller.setItemActive(item, isActive: false);

        expect(itemNamed('Retired Special').isActive, isFalse);

        final List<MenuItem> billing = (await repository.loadItems(
          categoryId: categoryId,
        )).valueOrNull!;
        expect(
          billing.map((MenuItem i) => i.name),
          isNot(contains('Retired Special')),
        );
      },
    );

    test(
      'changing the price updates the item but not old bills (management view)',
      () async {
        await controller.createItem(
          categoryId: categoryId,
          name: 'Repriced',
          basePrice: Money.parse('100.00'),
          itemType: MenuItemType.veg,
        );
        final MenuItem item = itemNamed('Repriced');

        await controller.updateItem(
          item,
          name: 'Repriced',
          basePrice: Money.parse('150.00'),
          itemType: MenuItemType.veg,
          categoryId: categoryId,
        );

        expect(itemNamed('Repriced').basePrice, Money.parse('150.00'));
      },
    );

    test('an unavailable item is still listed but not sellable', () async {
      await controller.createItem(
        categoryId: categoryId,
        name: 'Sold Out',
        basePrice: Money.parse('60.00'),
        itemType: MenuItemType.veg,
      );
      final MenuItem item = itemNamed('Sold Out');

      await controller.setItemAvailable(item, isAvailable: false);

      final MenuItem managed = itemNamed('Sold Out');
      expect(managed.isAvailable, isFalse);
      expect(managed.isSellable, isFalse);

      // Billing still returns it (so it can be shown greyed out), but it cannot be sold.
      final List<MenuItem> billing = (await repository.loadItems(
        categoryId: categoryId,
      )).valueOrNull!;
      final MenuItem billingItem = billing.firstWhere(
        (MenuItem i) => i.name == 'Sold Out',
      );
      expect(billingItem.isSellable, isFalse);
    });
  });

  group('variants', () {
    late String itemId;

    setUp(() async {
      await controller.createCategory('Pizzas');
      final String categoryId = categoryNamed('Pizzas').id;
      await controller.createItem(
        categoryId: categoryId,
        name: 'Margherita',
        basePrice: Money.parse('150.00'),
        itemType: MenuItemType.veg,
      );
      itemId = itemNamed('Margherita').id;
      await controller.selectVariantItem(itemId);
    });

    test('create, edit and deactivate a size', () async {
      expect(
        await controller.createVariant(
          menuItemId: itemId,
          name: 'Medium',
          price: Money.parse('250.00'),
        ),
        isTrue,
      );

      MenuItemVariant medium = controller.variants.firstWhere(
        (MenuItemVariant v) => v.name == 'Medium',
      );
      expect(medium.price, Money.parse('250.00'));

      // Edit the price. Same id.
      await controller.updateVariant(
        medium,
        name: 'Medium',
        price: Money.parse('275.00'),
      );
      final MenuItemVariant edited = controller.variants.firstWhere(
        (MenuItemVariant v) => v.name == 'Medium',
      );
      expect(edited.id, medium.id);
      expect(edited.price, Money.parse('275.00'));

      // Deactivate: management still shows it, billing does not.
      medium = edited;
      await controller.setVariantActive(medium, isActive: false);
      expect(
        controller.variants
            .firstWhere((MenuItemVariant v) => v.id == medium.id)
            .isActive,
        isFalse,
      );

      final List<MenuItemVariant> billing = (await repository.loadVariants(
        itemId,
      )).valueOrNull!;
      expect(
        billing.map((MenuItemVariant v) => v.id),
        isNot(contains(medium.id)),
      );
    });

    test('an item may have no variants', () async {
      // Margherita has none until one is added.
      expect(controller.variants, isEmpty);
    });
  });

  group('options', () {
    late String categoryId;
    late String pizzaId;
    late String burgerId;

    setUp(() async {
      await controller.createCategory('Mains');
      categoryId = categoryNamed('Mains').id;
      await controller.createItem(
        categoryId: categoryId,
        name: 'Farmhouse',
        basePrice: Money.parse('200.00'),
        itemType: MenuItemType.veg,
      );
      await controller.createItem(
        categoryId: categoryId,
        name: 'Veg Burger',
        basePrice: Money.parse('80.00'),
        itemType: MenuItemType.veg,
      );
      pizzaId = itemNamed('Farmhouse').id;
      burgerId = itemNamed('Veg Burger').id;
    });

    MenuItemOption optionNamed(String name) =>
        controller.options.firstWhere((MenuItemOption o) => o.name == name);

    test('create, edit and deactivate a global option', () async {
      expect(
        await controller.createOption(
          name: 'House Dip',
          optionType: MenuOptionType.condiment,
          price: Money.parse('15.00'),
        ),
        isTrue,
      );

      MenuItemOption dip = optionNamed('House Dip');
      expect(dip.scope, MenuOptionScope.global);
      expect(dip.price, Money.parse('15.00'));

      await controller.updateOption(
        dip,
        name: 'House Dip',
        optionType: MenuOptionType.condiment,
        price: Money.parse('20.00'),
      );
      dip = optionNamed('House Dip');
      expect(dip.price, Money.parse('20.00'));

      await controller.setOptionActive(dip, isActive: false);
      expect(optionNamed('House Dip').isActive, isFalse);
    });

    test('an item-scoped option applies to that item, not another', () async {
      await controller.createOption(
        name: 'Stuffed Crust',
        optionType: MenuOptionType.crust,
        price: Money.parse('60.00'),
        menuItemId: pizzaId,
      );

      final MenuItemOption option = optionNamed('Stuffed Crust');
      expect(option.scope, MenuOptionScope.item);
      expect(option.menuItemId, pizzaId);

      final List<MenuItemOption> onPizza = (await repository.loadOptionsForItem(
        pizzaId,
      )).valueOrNull!;
      expect(
        onPizza.map((MenuItemOption o) => o.name),
        contains('Stuffed Crust'),
      );

      final List<MenuItemOption> onBurger =
          (await repository.loadOptionsForItem(burgerId)).valueOrNull!;
      expect(
        onBurger.map((MenuItemOption o) => o.name),
        isNot(contains('Stuffed Crust')),
        reason: 'an item-scoped option must not leak to another item',
      );
    });

    test('a variant-scoped option stays bound to that one size', () async {
      await controller.selectVariantItem(pizzaId);
      await controller.createVariant(
        menuItemId: pizzaId,
        name: 'Large',
        price: Money.parse('320.00'),
      );
      final MenuItemVariant large = controller.variants.firstWhere(
        (MenuItemVariant v) => v.name == 'Large',
      );

      await controller.createOption(
        name: 'Extra Toppings',
        optionType: MenuOptionType.addOn,
        price: Money.parse('45.00'),
        variantId: large.id,
      );

      final MenuItemOption option = optionNamed('Extra Toppings');
      expect(option.scope, MenuOptionScope.variant);
      expect(option.variantId, large.id);

      // Offered for that size.
      final List<MenuItemOption> forLarge =
          (await repository.loadOptionsForVariant(large.id)).valueOrNull!;
      expect(
        forLarge.map((MenuItemOption o) => o.name),
        contains('Extra Toppings'),
      );

      // Not offered on the burger, which has no size and never reaches this scope.
      final List<MenuItemOption> onBurger =
          (await repository.loadOptionsForItem(burgerId)).valueOrNull!;
      expect(
        onBurger.map((MenuItemOption o) => o.name),
        isNot(contains('Extra Toppings')),
      );
    });

    test('editing an option cannot change its scope', () async {
      await controller.createOption(
        name: 'Jalapenos',
        optionType: MenuOptionType.addOn,
        price: Money.parse('25.00'),
        menuItemId: pizzaId,
      );
      final MenuItemOption before = optionNamed('Jalapenos');

      await controller.updateOption(
        before,
        name: 'Sliced Jalapenos',
        optionType: MenuOptionType.addOn,
        price: Money.parse('30.00'),
      );

      final MenuItemOption after = optionNamed('Sliced Jalapenos');
      expect(after.id, before.id);
      expect(after.scope, MenuOptionScope.item);
      expect(after.menuItemId, pizzaId);
    });

    test('a multi-scope option is refused rather than made global', () async {
      final bool created = await controller.createOption(
        name: 'Confused',
        optionType: MenuOptionType.addOn,
        price: Money.parse('10.00'),
        menuItemId: pizzaId,
        categoryId: categoryId,
      );

      expect(created, isFalse);
      expect(controller.hasError, isTrue);
      expect(
        controller.options.map((MenuItemOption o) => o.name),
        isNot(contains('Confused')),
      );
    });
  });
}
