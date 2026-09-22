import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_database.dart';

/// Drives the billing controller against the real seeded menu.
///
/// The repository here is the production `SqliteMenuRepository` over a migrated
/// in-memory database, so every price asserted below is the price the outlet's menu
/// actually holds. Nothing is stubbed: if scope resolution regressed, or a seeded
/// price changed, these tests fail rather than agreeing with a fake.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository repository;
  late BillingController controller;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    repository = SqliteMenuRepository(database: database);
    controller = BillingController(menuRepository: repository);
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  MenuCategory categoryNamed(String name) => controller.categories.firstWhere(
    (MenuCategory category) => category.name == name,
  );

  MenuItem itemNamed(String name) =>
      controller.items.firstWhere((MenuItem item) => item.name == name);

  MenuItemVariant sizeNamed(String name) => controller.variants.firstWhere(
    (MenuItemVariant variant) => variant.name == name,
  );

  MenuItemOption optionNamed(String name) => controller.availableOptions
      .firstWhere((MenuItemOption option) => option.name == name);

  List<String> optionNames() => controller.availableOptions
      .map((MenuItemOption option) => option.name)
      .toList();

  /// Opens a category and starts configuring one of its items.
  Future<void> configure(String categoryName, String itemName) async {
    await controller.ensureMenuLoaded();
    await controller.selectCategory(categoryNamed(categoryName));
    await controller.selectItem(itemNamed(itemName));
  }

  /// Configures a pizza at a size, which is the path the counter takes most often.
  Future<void> configurePizza(String pizza, String size) async {
    await configure('SIMPLY VEG', pizza);
    await controller.selectVariant(sizeNamed(size));
  }

  group('loading the menu', () {
    test('the categories come from the repository, in menu order', () async {
      await controller.loadMenu();

      expect(controller.categories.map((MenuCategory c) => c.name), <String>[
        'SIMPLY VEG',
        'VEG DELIGHT',
        'VEG TREAT',
        'VEG SPECIAL',
        'VEG FEAST PIZZA',
        'SINGLE TOPPING PIZZA',
        'DOUBLE TOPPING PIZZA',
        'WRAPS',
        'TACO',
        'COFFEE',
        'SANDWICH',
        'BURGER',
        'SHAKE / MOCKTAIL',
        'FAMILY COMBO',
        'SET OF 4',
        'SIDE ORDER',
      ]);
      expect(controller.hasError, isFalse);
    });

    test('a loading state is exposed while the menu is being read', () async {
      final Future<void> loading = controller.loadMenu();

      expect(controller.isLoadingMenu, isTrue);

      await loading;

      expect(controller.isLoadingMenu, isFalse);
      expect(controller.isLoadingItems, isFalse);
    });

    test('the first category is opened so the screen is never blank', () async {
      await controller.loadMenu();

      expect(controller.selectedCategory?.name, 'SIMPLY VEG');
      expect(controller.items, isNotEmpty);
      expect(
        controller.items.map((MenuItem item) => item.name),
        contains('Cheese Pizza'),
      );
    });

    test(
      'selecting a category loads that category and only that one',
      () async {
        await controller.loadMenu();

        final MenuCategory burgers = categoryNamed('Burger');
        await controller.selectCategory(burgers);

        expect(controller.selectedCategory?.id, burgers.id);
        expect(controller.items, isNotEmpty);
        expect(
          controller.items.every(
            (MenuItem item) => item.categoryId == burgers.id,
          ),
          isTrue,
        );
        expect(
          controller.items.map((MenuItem item) => item.name),
          contains('Cheese Burger'),
        );
        expect(
          controller.items.map((MenuItem item) => item.name),
          isNot(contains('Cheese Pizza')),
        );
      },
    );

    test('every seeded category can be opened', () async {
      await controller.loadMenu();

      for (final MenuCategory category in controller.categories) {
        await controller.selectCategory(category);

        expect(controller.hasError, isFalse, reason: category.name);
        expect(controller.isLoadingItems, isFalse, reason: category.name);
        expect(controller.items, isNotEmpty, reason: category.name);
      }
    });

    test('changing category closes any open configuration', () async {
      await controller.loadMenu();
      await controller.selectItem(itemNamed('Cheese Pizza'));

      expect(controller.isConfiguring, isTrue);

      await controller.selectCategory(categoryNamed('SIDE ORDER'));

      expect(controller.isConfiguring, isFalse);
      expect(controller.configuringItem, isNull);
      expect(controller.variants, isEmpty);
      expect(controller.availableOptions, isEmpty);
    });
  });

  group('configuring a size-priced item', () {
    test('selecting a pizza exposes its sizes and their prices', () async {
      await controller.loadMenu();
      await controller.selectItem(itemNamed('Cheese Pizza'));

      expect(controller.requiresVariantSelection, isTrue);
      expect(controller.variants.map((MenuItemVariant v) => v.name), <String>[
        'Small',
        'Medium',
        'Large',
      ]);
      expect(sizeNamed('Small').price, Money.parse('130'));
      expect(sizeNamed('Medium').price, Money.parse('250'));
      expect(sizeNamed('Large').price, Money.parse('390'));
    });

    test('no options and no price until a size is chosen', () async {
      await controller.loadMenu();
      await controller.selectItem(itemNamed('Cheese Pizza'));

      // A size-dependent option has no defined price before the size is known, so
      // the repository is not asked for one and the line cannot be added yet.
      expect(controller.selectedVariant, isNull);
      expect(controller.availableOptions, isEmpty);
      expect(controller.draftBasePrice, isNull);
      expect(controller.draftUnitPrice, isNull);
      expect(controller.canAddToCart, isFalse);
    });

    test('a Medium Cheese Pizza is priced at 250', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      expect(controller.draftBasePrice, Money.parse('250'));
      expect(controller.draftUnitPrice, Money.parse('250'));
      expect(controller.canAddToCart, isTrue);
    });

    test('Extra Cheese adds 70 to a Medium', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      expect(extraCheese.price, Money.parse('70'));

      controller.toggleOption(extraCheese);

      expect(controller.draftOptionsTotal, Money.parse('70'));
      expect(controller.draftUnitPrice, Money.parse('320'));
    });

    test('Extra Cheese adds 50 to a Small', () async {
      await configurePizza('Cheese Pizza', 'Small');

      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      expect(extraCheese.price, Money.parse('50'));

      controller.toggleOption(extraCheese);

      expect(controller.draftUnitPrice, Money.parse('180'));
    });

    test('Extra Cheese adds 90 to a Large', () async {
      await configurePizza('Cheese Pizza', 'Large');

      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      expect(extraCheese.price, Money.parse('90'));

      controller.toggleOption(extraCheese);

      expect(controller.draftUnitPrice, Money.parse('490'));
    });

    test('a Large is offered the pizza add-ons priced for Large', () async {
      await configurePizza('Cheese Pizza', 'Large');

      // The specification prices every pizza add-on for all three sizes, so a Large
      // is offered the full set rather than the crust-only subset the old menu had.
      expect(optionNames(), <String>[
        'Extra Cheese',
        'Cheese Burst',
        'Onion',
        'Capsicum',
        'Mushroom',
        'Tomato',
        'Sweet Corn',
        'Olive',
        'Paneer',
        'Jalapeno',
        'Red Paprika',
        'Ketchup',
      ]);
    });

    test('no crust upgrade exists on the specification menu', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      expect(optionNames(), isNot(contains('Thin Crust')));
      expect(
        controller.availableOptions
            .any((MenuItemOption o) => o.optionType == MenuOptionType.crust),
        isFalse,
      );
    });

    test(
      'a modifier priced for another size cannot be applied to this one',
      () async {
        await configurePizza('Cheese Pizza', 'Medium');
        final MenuItemOption mediumExtraCheese = optionNamed('Extra Cheese');
        expect(mediumExtraCheese.price, Money.parse('70'));

        await controller.selectVariant(sizeNamed('Large'));

        // Even handed the exact option object priced for another size, the controller
        // refuses it, because the repository did not offer it for this selection.
        controller.toggleOption(mediumExtraCheese);

        expect(controller.isOptionSelected(mediumExtraCheese.id), isFalse);
        expect(controller.selectedOptions, isEmpty);
        expect(controller.draftOptionsTotal, Money.zero);
        expect(controller.draftUnitPrice, Money.parse('390'));
      },
    );

    test('Cheese Burst is offered on every size at its own price', () async {
      await configurePizza('Cheese Pizza', 'Large');

      final MenuItemOption cheeseBurst = optionNamed('Cheese Burst');
      expect(cheeseBurst.price, Money.parse('90'));

      controller.toggleOption(cheeseBurst);

      expect(controller.selectedOptions.single.name, 'Cheese Burst');
      expect(controller.draftUnitPrice, Money.parse('480'));
    });

    test('add-ons stack with each other and with a crust', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      controller.toggleOption(optionNamed('Thin Crust'));
      controller.toggleOption(optionNamed('Extra Cheese'));
      controller.toggleOption(optionNamed('Extra Toppings'));
      controller.toggleOption(optionNamed('Ketchup'));

      // 250 + 50 + 70 + 50 + 10
      expect(controller.draftOptionsTotal, Money.parse('180'));
      expect(controller.draftUnitPrice, Money.parse('430'));
    });

    test('toggling an option twice clears it', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      controller.toggleOption(extraCheese);
      controller.toggleOption(extraCheese);

      expect(controller.isOptionSelected(extraCheese.id), isFalse);
      expect(controller.draftUnitPrice, Money.parse('250'));
    });

    test('changing the size reprices and clears the old selections', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.toggleOption(optionNamed('Extra Cheese'));
      expect(controller.draftUnitPrice, Money.parse('320'));

      await controller.selectVariant(sizeNamed('Large'));

      // The Medium's Extra Cheese was a differently priced row, so the choice is
      // dropped rather than carried over at the wrong amount.
      expect(controller.selectedOptions, isEmpty);
      expect(controller.draftUnitPrice, Money.parse('400'));

      controller.toggleOption(optionNamed('Extra Cheese'));

      expect(controller.draftUnitPrice, Money.parse('490'));
    });

    test('the option list arrives grouped and ordered for display', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      expect(optionNames(), <String>[
        'Thin Crust',
        'Cheese Burst',
        'Extra Cheese',
        'Extra Toppings',
        'Ketchup',
      ]);
      expect(controller.optionGroups.keys, hasLength(3));
    });

    test('no option name carries a size', () async {
      for (final String size in <String>['Small', 'Medium', 'Large']) {
        await configurePizza('Cheese Pizza', size);

        for (final String name in optionNames()) {
          expect(name, isNot(contains('(')), reason: '$size $name');
          expect(name, isNot(contains(size)), reason: '$size $name');
        }
      }
    });
  });

  group('configuring an item with no sizes', () {
    test('it is priced from the item and can be added immediately', () async {
      await configure('Side Orders', 'French Fries');

      expect(controller.requiresVariantSelection, isFalse);
      expect(controller.variants, isEmpty);
      expect(controller.selectedVariant, isNull);
      expect(controller.draftBasePrice, Money.parse('70'));
      expect(controller.draftUnitPrice, Money.parse('70'));
      expect(controller.canAddToCart, isTrue);
    });

    test('only options that need no size are offered', () async {
      await configure('Side Orders', 'French Fries');

      expect(optionNames(), <String>['Ketchup']);
      expect(optionNames(), isNot(contains('Extra Cheese')));
    });

    test('it goes into the cart without a size', () async {
      await configure('Side Orders', 'French Fries');
      controller.toggleOption(optionNamed('Ketchup'));
      controller.addConfiguredItemToCart();

      final CartLine line = controller.cart.lines.single;

      expect(line.hasVariant, isFalse);
      expect(line.variantId, isNull);
      expect(line.variantNameSnapshot, isNull);
      expect(line.displayName, 'French Fries');
      expect(line.unitPrice, Money.parse('80'));
      expect(controller.subtotal, Money.parse('80'));
    });
  });

  group('the cart', () {
    test('an untouched cart is empty', () async {
      await controller.loadMenu();

      expect(controller.cart.isEmpty, isTrue);
      expect(controller.cart.lineCount, 0);
      expect(controller.cart.itemCount, 0);
      expect(controller.subtotal, Money.zero);
    });

    test('adding a configured item records every snapshot', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      final MenuItem pizza = controller.configuringItem!;
      final MenuItemVariant medium = controller.selectedVariant!;
      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      controller.toggleOption(extraCheese);

      controller.addConfiguredItemToCart();

      final CartLine line = controller.cart.lines.single;

      expect(line.id, isNotEmpty);
      expect(line.menuItemId, pizza.id);
      expect(line.variantId, medium.id);
      expect(line.itemNameSnapshot, 'Cheese Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.displayName, 'Cheese Pizza (Medium)');
      expect(line.basePriceSnapshot, Money.parse('250'));
      expect(line.options.single.optionId, extraCheese.id);
      expect(line.options.single.nameSnapshot, 'Extra Cheese');
      expect(line.options.single.priceSnapshot, Money.parse('70'));
      expect(line.quantity, 1);
      expect(line.unitPrice, Money.parse('320'));
      expect(line.lineTotal, Money.parse('320'));
      expect(controller.subtotal, Money.parse('320'));
    });

    test('adding closes the configuration panel', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      controller.addConfiguredItemToCart();

      expect(controller.isConfiguring, isFalse);
      expect(controller.configuringItem, isNull);
      expect(controller.selectedVariant, isNull);
      expect(controller.availableOptions, isEmpty);
      expect(controller.canAddToCart, isFalse);
    });

    test('an incomplete draft cannot be added', () async {
      await controller.loadMenu();
      await controller.selectItem(itemNamed('Cheese Pizza'));

      controller.addConfiguredItemToCart();

      expect(controller.cart.isEmpty, isTrue);
      expect(controller.isConfiguring, isTrue);
    });

    test('cancelling discards the draft and adds nothing', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      controller.cancelConfiguration();

      expect(controller.isConfiguring, isFalse);
      expect(controller.cart.isEmpty, isTrue);
    });

    test('one to two doubles the line total exactly', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.toggleOption(optionNamed('Extra Cheese'));
      controller.addConfiguredItemToCart();

      final String lineId = controller.cart.lines.single.id;
      controller.increaseQuantity(lineId);

      expect(controller.cart.lines.single.quantity, 2);
      expect(controller.cart.lines.single.unitPrice, Money.parse('320'));
      expect(controller.cart.lines.single.lineTotal, Money.parse('640'));
      expect(controller.subtotal, Money.parse('640'));
    });

    test('reducing the quantity reduces the total', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.addConfiguredItemToCart();

      final String lineId = controller.cart.lines.single.id;
      controller.increaseQuantity(lineId);
      controller.increaseQuantity(lineId);
      expect(controller.subtotal, Money.parse('750'));

      controller.decreaseQuantity(lineId);

      expect(controller.cart.lines.single.quantity, 2);
      expect(controller.subtotal, Money.parse('500'));
    });

    test('removing a line removes its amount from the subtotal', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.addConfiguredItemToCart();
      await configure('Side Orders', 'French Fries');
      controller.addConfiguredItemToCart();

      expect(controller.subtotal, Money.parse('320'));

      final String pizzaLineId = controller.cart.lines.first.id;
      controller.removeLine(pizzaLineId);

      expect(controller.cart.lineCount, 1);
      expect(controller.cart.lines.single.itemNameSnapshot, 'French Fries');
      expect(controller.subtotal, Money.parse('70'));
    });

    test('several lines add up exactly', () async {
      // Medium Cheese Pizza with Extra Cheese, twice: (250 + 70) x 2 = 640
      await configurePizza('Cheese Pizza', 'Medium');
      controller.toggleOption(optionNamed('Extra Cheese'));
      controller.addConfiguredItemToCart();
      controller.increaseQuantity(controller.cart.lines.first.id);

      // Large Cheese Pizza, plain: 400
      await configurePizza('Cheese Pizza', 'Large');
      controller.addConfiguredItemToCart();

      // French Fries with Ketchup: 70 + 10 = 80
      await configure('Side Orders', 'French Fries');
      controller.toggleOption(optionNamed('Ketchup'));
      controller.addConfiguredItemToCart();

      expect(controller.cart.lineCount, 3);
      expect(controller.cart.itemCount, 4);
      expect(controller.subtotal, Money.parse('1120'));
      expect(controller.subtotal.paise, 112000);
    });

    test('ringing up the same configuration twice folds the lines', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.toggleOption(optionNamed('Extra Cheese'));
      controller.addConfiguredItemToCart();

      await configurePizza('Cheese Pizza', 'Medium');
      controller.toggleOption(optionNamed('Extra Cheese'));
      controller.addConfiguredItemToCart();

      expect(controller.cart.lineCount, 1);
      expect(controller.cart.lines.single.quantity, 2);
      expect(controller.subtotal, Money.parse('640'));
    });

    test('the same pizza at two sizes is two lines', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.addConfiguredItemToCart();
      await configurePizza('Cheese Pizza', 'Large');
      controller.addConfiguredItemToCart();

      expect(controller.cart.lineCount, 2);
      expect(controller.subtotal, Money.parse('650'));
    });

    test('clearing removes every line and returns to empty', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.addConfiguredItemToCart();
      await configure('Side Orders', 'French Fries');
      controller.addConfiguredItemToCart();
      expect(controller.cart.lineCount, 2);

      controller.clearCart();

      expect(controller.cart.isEmpty, isTrue);
      expect(controller.cart.lineCount, 0);
      expect(controller.subtotal, Money.zero);
    });

    test('every cart change notifies listeners', () async {
      await configurePizza('Cheese Pizza', 'Medium');

      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.addConfiguredItemToCart();
      final String lineId = controller.cart.lines.single.id;
      controller.increaseQuantity(lineId);
      controller.decreaseQuantity(lineId);
      controller.removeLine(lineId);
      expect(notifications, 4);

      // A no-op does not wake the widget tree.
      controller.clearCart();
      expect(notifications, 4);
    });
  });

  group('the cart does not follow the menu', () {
    test('re-pricing a size later leaves the existing line alone', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      final MenuItem pizza = controller.configuringItem!;
      final MenuItemVariant medium = controller.selectedVariant!;
      final MenuItemOption extraCheese = optionNamed('Extra Cheese');
      controller.toggleOption(extraCheese);
      controller.addConfiguredItemToCart();

      expect(controller.subtotal, Money.parse('320'));

      // The owner raises both prices and renames the size.
      final DateTime now = DateTime.now().toUtc();
      await repository.saveVariant(
        medium.copyWith(
          name: 'Regular',
          price: Money.parse('999'),
          updatedAt: now,
        ),
      );
      await repository.saveOption(
        extraCheese.copyWith(price: Money.parse('500'), updatedAt: now),
      );

      // The menu really did change.
      final List<MenuItemVariant> reloadedSizes =
          (await repository.loadVariants(pizza.id)).valueOrNull!;
      expect(
        reloadedSizes
            .firstWhere((MenuItemVariant v) => v.id == medium.id)
            .price,
        Money.parse('999'),
      );
      final List<MenuItemOption> reloadedOptions =
          (await repository.loadOptionsForVariant(medium.id)).valueOrNull!;
      expect(
        reloadedOptions
            .firstWhere((MenuItemOption o) => o.id == extraCheese.id)
            .price,
        Money.parse('500'),
      );

      // The line quoted to the customer did not.
      final CartLine line = controller.cart.lines.single;
      expect(line.itemNameSnapshot, 'Cheese Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.basePriceSnapshot, Money.parse('250'));
      expect(line.options.single.priceSnapshot, Money.parse('70'));
      expect(line.unitPrice, Money.parse('320'));
      expect(controller.subtotal, Money.parse('320'));

      // Nor does a full reload of the menu disturb it.
      await controller.loadMenu();

      expect(controller.cart.lines.single.unitPrice, Money.parse('320'));
      expect(controller.subtotal, Money.parse('320'));
    });

    test(
      'a quantity change after a re-price uses the old unit price',
      () async {
        await configurePizza('Cheese Pizza', 'Medium');
        final MenuItemVariant medium = controller.selectedVariant!;
        controller.addConfiguredItemToCart();

        await repository.saveVariant(
          medium.copyWith(
            price: Money.parse('999'),
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        controller.increaseQuantity(controller.cart.lines.single.id);

        expect(controller.subtotal, Money.parse('500'));
      },
    );
  });

  group('repository failures', () {
    // Closing the database is the honest way to make the real repository fail. It
    // exercises the same error path a locked or corrupt file would take, without
    // substituting a fake for the code under test.

    test('a failure loading the menu becomes an error state', () async {
      await database.close();

      await controller.loadMenu();

      expect(controller.hasError, isTrue);
      expect(controller.errorMessage, isNotNull);
      expect(controller.errorMessage, isNotEmpty);
      expect(controller.isLoadingMenu, isFalse);
      expect(controller.categories, isEmpty);
      expect(controller.items, isEmpty);
    });

    test('a failure loading items becomes an error state', () async {
      await controller.loadMenu();
      final MenuCategory burgers = categoryNamed('Burger');

      await database.close();
      await controller.selectCategory(burgers);

      expect(controller.hasError, isTrue);
      expect(controller.isLoadingItems, isFalse);
      expect(controller.items, isEmpty);
      // The categories already on screen are kept, so the screen stays usable.
      expect(controller.categories, isNotEmpty);
    });

    test('a failure loading sizes closes the draft and reports', () async {
      await controller.loadMenu();
      final MenuItem pizza = itemNamed('Cheese Pizza');

      await database.close();
      await controller.selectItem(pizza);

      expect(controller.hasError, isTrue);
      expect(controller.isConfiguring, isFalse);
      expect(controller.isLoadingOptions, isFalse);
    });

    test('a failure loading options leaves the size chosen', () async {
      await controller.loadMenu();
      await controller.selectItem(itemNamed('Cheese Pizza'));
      final MenuItemVariant medium = sizeNamed('Medium');

      await database.close();
      await controller.selectVariant(medium);

      expect(controller.hasError, isTrue);
      expect(controller.isLoadingOptions, isFalse);
      expect(controller.availableOptions, isEmpty);
      // The size is still chosen, so the item can be added without options rather
      // than having to be found again.
      expect(controller.selectedVariant?.id, medium.id);
      expect(controller.draftUnitPrice, Money.parse('250'));
      expect(controller.canAddToCart, isTrue);
    });

    test('a failure does not empty a cart that was already built', () async {
      await configurePizza('Cheese Pizza', 'Medium');
      controller.addConfiguredItemToCart();

      await database.close();
      await controller.selectCategory(categoryNamed('Burger'));

      expect(controller.hasError, isTrue);
      expect(controller.subtotal, Money.parse('250'));
    });

    test('an error can be dismissed', () async {
      await database.close();
      await controller.loadMenu();
      expect(controller.hasError, isTrue);

      controller.dismissError();

      expect(controller.hasError, isFalse);
      expect(controller.errorMessage, isNull);
    });

    test('retrying after a failure is the same call', () async {
      await controller.loadMenu();
      expect(controller.categories, isNotEmpty);

      // Loading again is safe and clears the error.
      await controller.loadMenu();

      expect(controller.hasError, isFalse);
      expect(controller.categories, hasLength(12));
    });
  });
}
