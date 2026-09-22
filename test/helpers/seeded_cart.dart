import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/repositories/held_bill_repository.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/repositories/menu_repository.dart';

/// Builds carts out of the real seeded menu, the way a cashier does.
///
/// Checkout tests need a cart whose prices and snapshots are genuine. Assembling one
/// through [BillingController] means every amount asserted downstream came from the
/// seeded menu by way of the production repository, so a change to either is caught
/// here rather than agreed with.
class SeededCart {
  const SeededCart._();

  /// A billing controller with the menu loaded.
  ///
  /// Pass [heldBills] to wire hold support, which is what the hold tests need. Left out,
  /// the controller cannot hold — [BillingController.canHold] is false — which is the state
  /// a cart-only test wants.
  static Future<BillingController> controller(
    MenuRepository menu, {
    HeldBillRepository? heldBills,
  }) async {
    final BillingController controller = BillingController(
      menuRepository: menu,
      heldBillRepository: heldBills,
    );
    await controller.loadMenu();
    return controller;
  }

  /// Adds one configured line: an item, optionally at a size, with options by name.
  ///
  /// Throws [StateError] when a name does not exist in the menu, so a typo in a test
  /// fails loudly instead of silently adding nothing.
  static Future<void> add(
    BillingController controller, {
    required String category,
    required String item,
    String? size,
    List<String> options = const <String>[],
    int quantity = 1,
  }) async {
    await controller.selectCategory(_named(controller.categories, category));
    await controller.selectItem(_itemNamed(controller.items, item));

    if (size != null) {
      await controller.selectVariant(_sizeNamed(controller.variants, size));
    }

    for (final String option in options) {
      controller.toggleOption(
        _optionNamed(controller.availableOptions, option),
      );
    }

    controller.addConfiguredItemToCart();

    if (quantity > 1) {
      final String lineId = controller.cart.lines.last.id;
      for (int added = 1; added < quantity; added++) {
        controller.increaseQuantity(lineId);
      }
    }
  }

  /// A cart holding one configured line, built through the production controller.
  ///
  /// For a test that cares about what was sold rather than about the taps that sold it.
  static Future<Cart> cartOf(
    MenuRepository menu, {
    required String category,
    required String item,
    String? size,
    List<String> options = const <String>[],
    int quantity = 1,
  }) async {
    final BillingController controller = await SeededCart.controller(menu);
    await add(
      controller,
      category: category,
      item: item,
      size: size,
      options: options,
      quantity: quantity,
    );
    final Cart cart = controller.cart;
    controller.dispose();
    return cart;
  }

  /// A cart holding one Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  ///
  /// The canonical bill for these tests, because every figure in it is asserted
  /// independently by the menu seed tests.
  static Future<Cart> mediumCheesePizzaWithExtraCheese(
    MenuRepository menu, {
    int quantity = 1,
  }) async {
    final BillingController controller = await SeededCart.controller(menu);
    await add(
      controller,
      category: 'SIMPLY VEG',
      item: 'Cheese Pizza',
      size: 'Medium',
      options: <String>['Extra Cheese'],
      quantity: quantity,
    );
    final Cart cart = controller.cart;
    controller.dispose();
    return cart;
  }

  static MenuCategory _named(List<MenuCategory> categories, String name) {
    for (final MenuCategory category in categories) {
      if (category.name == name) {
        return category;
      }
    }
    throw StateError('No seeded category named "$name"');
  }

  static MenuItem _itemNamed(List<MenuItem> items, String name) {
    for (final MenuItem item in items) {
      if (item.name == name) {
        return item;
      }
    }
    throw StateError('No seeded item named "$name"');
  }

  static MenuItemVariant _sizeNamed(
    List<MenuItemVariant> variants,
    String name,
  ) {
    for (final MenuItemVariant variant in variants) {
      if (variant.name == name) {
        return variant;
      }
    }
    throw StateError('No seeded size named "$name"');
  }

  static MenuItemOption _optionNamed(
    List<MenuItemOption> options,
    String name,
  ) {
    for (final MenuItemOption option in options) {
      if (option.name == name) {
        return option;
      }
    }
    throw StateError('No option named "$name" is offered for this selection');
  }
}
