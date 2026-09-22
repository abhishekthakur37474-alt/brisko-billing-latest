import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_ingredient.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_type.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/presentation/controllers/menu_management_controller.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

/// Proves that a menu change made by the owner reaches the counter, the kitchen and
/// the stock ledger the way the requirement demands, and — just as importantly — that
/// it leaves settled bills, recipes and item identities alone.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late MenuManagementController controller;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    controller = MenuManagementController(menuRepository: menu);
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  MenuCategory categoryNamed(String name) =>
      controller.categories.firstWhere((MenuCategory c) => c.name == name);

  MenuItem itemNamed(String name) =>
      controller.items.firstWhere((MenuItem i) => i.name == name);

  Future<String> makeItem(String name, String price) async {
    await controller.createCategory('Integration Section');
    final String categoryId = categoryNamed('Integration Section').id;
    await controller.createItem(
      categoryId: categoryId,
      name: name,
      basePrice: Money.parse(price),
      itemType: MenuItemType.veg,
    );
    return itemNamed(name).id;
  }

  test('changing an item price does not rewrite a settled bill', () async {
    final String itemId = await makeItem('Combo Meal', '199.00');

    // A bill that sold the item at its original price.
    final SqliteOrderRepository orders = SqliteOrderRepository(
      database: database,
    );
    final order = Fixtures.order(
      orderNumber: 'HIST-0001',
      subtotal: '199.00',
      tax: '0.00',
      total: '199.00',
    );
    final OrderItem line = Fixtures.orderItem(
      orderId: order.id,
      menuItemId: itemId,
      itemName: 'Combo Meal',
      variantName: null,
      quantity: 1,
      unitPrice: '199.00',
      total: '199.00',
    );
    expect(
      (await orders.saveOrder(order, items: <OrderItem>[line])).isOk,
      isTrue,
    );

    // Reprice the item.
    await controller.updateItem(
      itemNamed('Combo Meal'),
      name: 'Combo Meal',
      basePrice: Money.parse('249.00'),
      itemType: MenuItemType.veg,
      categoryId: itemNamed('Combo Meal').categoryId,
    );

    // The menu now says 249; the old bill line still says 199.
    expect(
      (await menu.findItem(itemId)).valueOrNull!.basePrice,
      Money.parse('249.00'),
    );

    final List<OrderItem> historical = (await orders.loadItems(order.id))
        .valueOrNull!;
    expect(historical.single.unitPrice, Money.parse('199.00'));
    expect(historical.single.menuItemId, itemId);
  });

  test('editing an item keeps its id, so a recipe stays linked', () async {
    final String itemId = await makeItem('Pasta', '140.00');

    // A stock item and a recipe line that uses it for this dish.
    final SqliteInventoryRepository inventory = SqliteInventoryRepository(
      database: database,
    );
    final stock = Fixtures.inventoryItem(
      name: 'Pasta Sheets',
      currentQuantity: '0',
    );
    expect((await inventory.saveItem(stock)).isOk, isTrue);

    final SqliteRecipeRepository recipes = SqliteRecipeRepository(
      database: database,
    );
    expect(
      (await recipes.addIngredient(
        scope: RecipeScope.product(itemId),
        inventoryItemId: stock.id,
        quantityMilli: 200,
      )).isOk,
      isTrue,
    );

    // Rename and reprice the dish.
    await controller.updateItem(
      itemNamed('Pasta'),
      name: 'White Sauce Pasta',
      basePrice: Money.parse('160.00'),
      itemType: MenuItemType.veg,
      categoryId: itemNamed('Pasta').categoryId,
    );

    // The recipe still points at the same item id.
    final List<RecipeIngredient> lines =
        (await recipes.loadIngredientsForMenuItem(itemId)).valueOrNull!;
    expect(lines, hasLength(1));
    expect(lines.single.inventoryItemId, stock.id);
    expect(
      (await menu.findItem(itemId)).valueOrNull!.name,
      'White Sauce Pasta',
    );
  });

  test('a combo item is edited like any other item without breaking', () async {
    // A combo has no dedicated schema: it is a menu item with a description. Editing it
    // is the same path as any item, and keeps the same id.
    await controller.createCategory('Combos');
    final String categoryId = categoryNamed('Combos').id;
    await controller.createItem(
      categoryId: categoryId,
      name: 'Family Combo',
      basePrice: Money.parse('499.00'),
      itemType: MenuItemType.veg,
      description: 'Two pizzas, one garlic bread, one drink',
    );
    final MenuItem before = itemNamed('Family Combo');

    final bool edited = await controller.updateItem(
      before,
      name: 'Family Feast',
      basePrice: Money.parse('549.00'),
      itemType: MenuItemType.veg,
      categoryId: categoryId,
      description: 'Two pizzas, two garlic breads, two drinks',
    );

    expect(edited, isTrue);
    final MenuItem after = itemNamed('Family Feast');
    expect(after.id, before.id);
    expect(after.basePrice, Money.parse('549.00'));
    expect(after.description, 'Two pizzas, two garlic breads, two drinks');
  });

  group('billing reflects the current active menu', () {
    late BillingController billing;

    setUp(() {
      billing = BillingController(menuRepository: menu);
    });

    tearDown(() => billing.dispose());

    test('a repriced item shows its new price after a reload', () async {
      await makeItem('Cola', '40.00');
      final MenuCategory category = categoryNamed('Integration Section');

      await billing.loadMenu();
      await billing.selectCategory(category);
      expect(
        billing.items.firstWhere((MenuItem i) => i.name == 'Cola').basePrice,
        Money.parse('40.00'),
      );

      await controller.updateItem(
        itemNamed('Cola'),
        name: 'Cola',
        basePrice: Money.parse('45.00'),
        itemType: MenuItemType.veg,
        categoryId: itemNamed('Cola').categoryId,
      );

      await billing.reloadMenu();
      expect(
        billing.items.firstWhere((MenuItem i) => i.name == 'Cola').basePrice,
        Money.parse('45.00'),
      );
    });

    test('a deactivated item disappears from the billing grid', () async {
      await makeItem('Limited Edition', '75.00');
      final MenuCategory category = categoryNamed('Integration Section');

      await billing.loadMenu();
      await billing.selectCategory(category);
      expect(
        billing.items.map((MenuItem i) => i.name),
        contains('Limited Edition'),
      );

      await controller.setItemActive(
        itemNamed('Limited Edition'),
        isActive: false,
      );

      await billing.reloadMenu();
      expect(
        billing.items.map((MenuItem i) => i.name),
        isNot(contains('Limited Edition')),
      );
    });

    test('an unavailable item stays on the grid but is not sellable', () async {
      await makeItem('Out Of Stock', '55.00');
      final MenuCategory category = categoryNamed('Integration Section');

      await controller.setItemAvailable(
        itemNamed('Out Of Stock'),
        isAvailable: false,
      );

      await billing.loadMenu();
      await billing.selectCategory(category);

      final MenuItem shown = billing.items.firstWhere(
        (MenuItem i) => i.name == 'Out Of Stock',
      );
      expect(shown.isSellable, isFalse);

      // Selecting it is refused with a message rather than opening configuration.
      await billing.selectItem(shown);
      expect(billing.isConfiguring, isFalse);
      expect(billing.errorMessage, isNotNull);
    });

    test(
      'a deactivated size is excluded from selection at the counter',
      () async {
        final String itemId = await makeItem('Sized Thing', '100.00');
        await controller.selectVariantItem(itemId);
        await controller.createVariant(
          menuItemId: itemId,
          name: 'Small',
          price: Money.parse('100.00'),
        );
        await controller.createVariant(
          menuItemId: itemId,
          name: 'Large',
          price: Money.parse('180.00'),
        );
        final MenuItemVariant large = controller.variants.firstWhere(
          (MenuItemVariant v) => v.name == 'Large',
        );

        await controller.setVariantActive(large, isActive: false);

        // Billing only sees the active size.
        final List<MenuItemVariant> sellable = (await menu.loadVariants(itemId))
            .valueOrNull!;
        expect(sellable.map((MenuItemVariant v) => v.name), <String>['Small']);
      },
    );
  });
}
