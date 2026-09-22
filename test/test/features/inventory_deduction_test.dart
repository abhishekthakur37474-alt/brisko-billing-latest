import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_deduction_status.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/order_inventory_deduction.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement_type.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_quantity.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';

/// Automatic stock deduction, end to end over the real settlement transaction.
///
/// Every bill here is settled through the production checkout repository from a cart
/// assembled out of the real seeded menu, so a deduction asserted below is a deduction
/// against rows the application actually wrote.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteInventoryRepository inventory;
  late SqliteRecipeRepository recipes;
  late SqliteInventoryDeductionRepository deductions;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteKotRepository kots;

  late MenuItem pizza;
  late MenuItemVariant medium;
  late MenuItemVariant large;
  late InventoryItem flour;
  late InventoryItem cheese;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    recipes = SqliteRecipeRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    kots = SqliteKotRepository(database: database);

    pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
      (MenuItem item) => item.name == 'Cheese Pizza',
    );
    final List<MenuItemVariant> sizes = (await menu.loadVariants(pizza.id))
        .valueOrNull!;
    medium = sizes.firstWhere((MenuItemVariant v) => v.name == 'Medium');
    large = sizes.firstWhere((MenuItemVariant v) => v.name == 'Large');

    // Deliberately generous shelves, so a test that runs short did so because of the
    // behaviour it is testing rather than because of the fixture.
    flour = Fixtures.inventoryItem(name: 'Test Flour', currentQuantity: '50');
    cheese = Fixtures.inventoryItem(name: 'Test Cheese', currentQuantity: '20');
    await inventory.saveItem(flour);
    await inventory.saveItem(cheese);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  // --------------------------------------------------------------- arranging ---

  RecipeScope productScope() => RecipeScope.product(pizza.id);

  RecipeScope scopeFor(MenuItemVariant variant) =>
      RecipeScope.variant(menuItemId: pizza.id, variantId: variant.id);

  /// Configures one ingredient line, in the quantity one sold unit uses.
  Future<void> configure({
    required RecipeScope scope,
    required InventoryItem stockItem,
    required String quantity,
  }) async {
    final Result<Object?> result = await recipes.addIngredient(
      scope: scope,
      inventoryItemId: stockItem.id,
      quantityMilli: StockQuantity.parse(quantity),
    );
    expect(result.isOk, isTrue, reason: 'arranging the recipe must succeed');
  }

  /// Sets a shelf to exactly [quantity] by adjusting it, so the change has a movement
  /// behind it the way every other balance change does.
  Future<void> setBalance(InventoryItem item, String quantity) async {
    final int target = StockQuantity.parse(quantity);
    final int current = (await inventory.findItem(item.id))
        .valueOrNull!
        .currentQuantityMilli;
    if (target == current) {
      return;
    }
    final Result<Object?> result = await inventory.adjust(
      inventoryItemId: item.id,
      quantityMilli: target - current,
      reason: 'test arrangement',
    );
    expect(result.isOk, isTrue);
  }

  /// Settles a bill for a Cheese Pizza at [size], through the real transaction.
  Future<Order> sell({required MenuItemVariant size, int quantity = 1}) async {
    final Cart cart = await SeededCart.cartOf(
      menu,
      category: 'SIMPLY VEG',
      item: 'Cheese Pizza',
      size: size.name,
      quantity: quantity,
    );
    final Result<Order> settled = await checkout.settle(
      BillSettlement.fromCart(
        cart: cart,
        orderType: OrderType.takeaway,
        paymentMethod: PaymentMethod.cash,
      ),
    );
    expect(settled.isOk, isTrue, reason: 'the sale itself must succeed');
    return settled.valueOrNull!;
  }

  // ----------------------------------------------------------------- reading ---

  Future<int> balanceOf(InventoryItem item) async =>
      (await inventory.findItem(item.id)).valueOrNull!.currentQuantityMilli;

  Future<List<StockMovement>> ledgerOf(InventoryItem item) async =>
      (await inventory.loadMovements(item.id)).valueOrNull!;

  /// The sale movements written for one bill, across every shelf.
  Future<List<Map<String, Object?>>> saleMovementsFor(Order order) {
    return database.database.query(
      'stock_movements',
      where: 'referenceId = ? AND movementType = ?',
      whereArgs: <Object?>[order.id, StockMovementType.sale.name],
    );
  }

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  // ------------------------------------------------------------------- tests ---

  group('deducting a sale', () {
    test('one sold item deducts its recipe quantities', () async {
      await configure(
        scope: productScope(),
        stockItem: flour,
        quantity: '0.15',
      );
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );

      final Order order = await sell(size: medium);
      final OrderInventoryDeduction deduction =
          (await deductions.deductForOrder(order.id)).valueOrNull!;

      expect(deduction.status, InventoryDeductionStatus.deducted);
      expect(deduction.movementCount, 2);
      expect(deduction.orderNumberSnapshot, order.orderNumber);
      expect(await balanceOf(flour), 50000 - 150);
      expect(await balanceOf(cheese), 20000 - 100);
    });

    test('two of the same item doubles the deduction', () async {
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );

      final Order order = await sell(size: medium, quantity: 2);
      await deductions.deductForOrder(order.id);

      expect(await balanceOf(cheese), 20000 - 200);
    });

    test('three of the same item triples it', () async {
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );

      final Order order = await sell(size: medium, quantity: 3);
      await deductions.deductForOrder(order.id);

      expect(await balanceOf(cheese), 20000 - 300);
    });

    test('several lines using one shelf are added up into one movement', () async {
      // Two lines of pizza both use cheese, so it comes off the same shelf once. Two
      // movements racing to update one balance would be a needless risk and an
      // unreadable ledger.
      await configure(
        scope: scopeFor(medium),
        stockItem: cheese,
        quantity: '0.1',
      );
      await configure(
        scope: scopeFor(large),
        stockItem: cheese,
        quantity: '0.15',
      );

      final Cart cart = await SeededCart.controller(menu)
          .then((controller) async {
            await SeededCart.add(
              controller,
              category: 'SIMPLY VEG',
              item: 'Cheese Pizza',
              size: 'Medium',
              quantity: 2,
            );
            await SeededCart.add(
              controller,
              category: 'SIMPLY VEG',
              item: 'Cheese Pizza',
              size: 'Large',
            );
            final Cart built = controller.cart;
            controller.dispose();
            return built;
          });

      final Order order = (await checkout.settle(
        BillSettlement.fromCart(
          cart: cart,
          orderType: OrderType.takeaway,
          paymentMethod: PaymentMethod.cash,
        ),
      )).valueOrNull!;

      final OrderInventoryDeduction deduction =
          (await deductions.deductForOrder(order.id)).valueOrNull!;

      // 2 × 100 + 1 × 150.
      expect(await balanceOf(cheese), 20000 - 350);
      expect(deduction.movementCount, 1);
      expect(await saleMovementsFor(order), hasLength(1));
    });

    test(
      'a successful deduction writes movements referencing the bill',
      () async {
        await configure(
          scope: productScope(),
          stockItem: flour,
          quantity: '0.15',
        );

        final Order order = await sell(size: medium);
        await deductions.deductForOrder(order.id);

        final List<StockMovement> ledger = await ledgerOf(flour);
        final StockMovement sale = ledger.firstWhere(
          (StockMovement m) => m.isSale,
        );
        expect(sale.movementType, StockMovementType.sale);
        expect(sale.referenceId, order.id);
        expect(sale.quantityMilli, 150);
        expect(sale.signedQuantityMilli, -150);
      },
    );

    test(
      'a bill with nothing configured deducts nothing and says so',
      () async {
        final Order order = await sell(size: medium);

        final OrderInventoryDeduction deduction =
            (await deductions.deductForOrder(order.id)).valueOrNull!;

        // Processed and closed, with nothing invented.
        expect(deduction.status, InventoryDeductionStatus.deducted);
        expect(deduction.movementCount, 0);
        expect(deduction.deductedNothing, isTrue);
        expect(await balanceOf(flour), 50000);
        expect(await rowCount('stock_movements'), 0);
      },
    );
  });

  group('sizes', () {
    test('a size uses its own recipe', () async {
      await configure(
        scope: scopeFor(medium),
        stockItem: flour,
        quantity: '0.15',
      );
      await configure(
        scope: scopeFor(large),
        stockItem: flour,
        quantity: '0.25',
      );

      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      expect(await balanceOf(flour), 50000 - 150);
    });

    test('a different size uses its own recipe', () async {
      await configure(
        scope: scopeFor(medium),
        stockItem: flour,
        quantity: '0.15',
      );
      await configure(
        scope: scopeFor(large),
        stockItem: flour,
        quantity: '0.25',
      );

      final Order order = await sell(size: large);
      await deductions.deductForOrder(order.id);

      expect(await balanceOf(flour), 50000 - 250);
    });

    test(
      'a size with no recipe of its own falls back to the product',
      () async {
        // How an outlet writes one recipe covering every size.
        await configure(
          scope: productScope(),
          stockItem: flour,
          quantity: '0.2',
        );

        final Order order = await sell(size: large);
        await deductions.deductForOrder(order.id);

        expect(await balanceOf(flour), 50000 - 200);
      },
    );

    test("a size's own recipe overrides the product recipe entirely", () async {
      // Not merged. A size that states what it uses states all of it, so a shared
      // ingredient is not silently deducted twice.
      await configure(scope: productScope(), stockItem: flour, quantity: '0.2');
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );
      await configure(
        scope: scopeFor(large),
        stockItem: flour,
        quantity: '0.25',
      );

      final Order order = await sell(size: large);
      await deductions.deductForOrder(order.id);

      expect(await balanceOf(flour), 50000 - 250);
      expect(await balanceOf(cheese), 20000);
    });
  });

  group('items with no recipe', () {
    test('a missing recipe is reported by name, as it was sold', () async {
      final Order order = await sell(size: medium);

      final OrderInventoryDeduction deduction =
          (await deductions.deductForOrder(order.id)).valueOrNull!;

      expect(deduction.hasUnconfiguredItems, isTrue);
      expect(deduction.unconfiguredItems, <String>['Cheese Pizza (Medium)']);
      expect(deduction.operatorMessage, contains('No recipe configured'));
      expect(deduction.operatorMessage, contains('Cheese Pizza (Medium)'));
    });

    test(
      'a configured line still deducts alongside an unconfigured one',
      () async {
        // The whole reason a missing recipe is not an error: an outlet configures its
        // menu dish by dish, and the dishes already done must keep working.
        await configure(
          scope: scopeFor(medium),
          stockItem: flour,
          quantity: '0.15',
        );

        final Cart cart = await SeededCart.controller(menu)
            .then((controller) async {
              await SeededCart.add(
                controller,
                category: 'SIMPLY VEG',
                item: 'Cheese Pizza',
                size: 'Medium',
              );
              await SeededCart.add(
                controller,
                category: 'SIMPLY VEG',
                item: 'Cheese Pizza',
                size: 'Large',
              );
              final Cart built = controller.cart;
              controller.dispose();
              return built;
            });

        final Order order = (await checkout.settle(
          BillSettlement.fromCart(
            cart: cart,
            orderType: OrderType.takeaway,
            paymentMethod: PaymentMethod.cash,
          ),
        )).valueOrNull!;

        final OrderInventoryDeduction deduction =
            (await deductions.deductForOrder(order.id)).valueOrNull!;

        expect(deduction.status, InventoryDeductionStatus.deducted);
        expect(await balanceOf(flour), 50000 - 150);
        expect(deduction.unconfiguredItems, <String>['Cheese Pizza (Large)']);
      },
    );

    test('unconfigured bills are listed for the operator', () async {
      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      final List<OrderInventoryDeduction> listed =
          (await deductions.loadUnconfiguredDeductions()).valueOrNull!;

      expect(listed, hasLength(1));
      expect(listed.single.orderNumberSnapshot, order.orderNumber);
    });

    test('an add-on with no recipe relationship deducts nothing', () async {
      // Options are not part of the recipe model in this step. Nothing is invented
      // for them, and nothing about them breaks the deduction of the line they sit on.
      await configure(
        scope: scopeFor(medium),
        stockItem: cheese,
        quantity: '0.1',
      );

      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(menu);
      final Order order = (await checkout.settle(
        BillSettlement.fromCart(
          cart: cart,
          orderType: OrderType.takeaway,
          paymentMethod: PaymentMethod.cash,
        ),
      )).valueOrNull!;

      await deductions.deductForOrder(order.id);

      // Exactly the line's recipe, with nothing added for the Extra Cheese option.
      expect(await balanceOf(cheese), 20000 - 100);
    });
  });

  group('not enough stock', () {
    setUp(() async {
      await configure(
        scope: productScope(),
        stockItem: flour,
        quantity: '0.15',
      );
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );
    });

    test('a shortfall deducts nothing at all', () async {
      // Flour is fine, cheese is not. Neither moves: half a bill's ingredients off the
      // shelf would leave two balances wrong in opposite directions.
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);

      final Result<OrderInventoryDeduction> result = await deductions
          .deductForOrder(order.id);

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await balanceOf(flour), 50000);
      expect(await balanceOf(cheese), 50);
      expect(await saleMovementsFor(order), isEmpty);
    });

    test('the shortfall names the item and the figures', () async {
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);

      final Result<OrderInventoryDeduction> result = await deductions
          .deductForOrder(order.id);

      expect(result.failureOrNull!.message, contains('Test Cheese'));
      expect(result.failureOrNull!.message, contains('0.1 kg needed'));
      expect(result.failureOrNull!.message, contains('0.05 kg in stock'));
    });

    test('no balance is left negative', () async {
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      final List<Map<String, Object?>> negative = await database.database.query(
        'inventory_items',
        where: 'currentQuantityMilli < 0',
      );
      expect(negative, isEmpty);
    });

    test('the failure is recorded for the operator to resolve', () async {
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      final OrderInventoryDeduction? recorded = (await deductions.findDeduction(
        order.id,
      )).valueOrNull;

      expect(recorded, isNotNull);
      expect(recorded!.status, InventoryDeductionStatus.failed);
      expect(recorded.attemptCount, 1);
      expect(recorded.movementCount, 0);
      expect(recorded.failureMessage, contains('Test Cheese'));
      // Never worded as a problem with the sale.
      expect(recorded.operatorMessage, contains('is settled'));

      expect(
        (await deductions.loadFailedDeductions()).valueOrNull,
        hasLength(1),
      );
    });

    test('the sale stays settled, paid and sent to the kitchen', () async {
      // The rule this whole design exists for: a shelf that is short never rolls back
      // a payment.
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      expect((await orders.findOrder(order.id)).valueOrNull, isNotNull);
      final List<Payment> tendered = (await payments.loadForOrder(order.id))
          .valueOrNull!;
      expect(tendered, hasLength(1));
      expect(tendered.single.status, PaymentStatus.completed);
      expect(tendered.single.amount, order.totalAmount);

      final List<KitchenTicket> board =
          (await kots.loadActiveTickets()).valueOrNull!;
      expect(board.map((KitchenTicket t) => t.orderNumber), <String>[
        order.orderNumber,
      ]);
    });

    test('a failed attempt succeeds once the stock is corrected', () async {
      await setBalance(cheese, '0.05');
      final Order order = await sell(size: medium);
      expect((await deductions.deductForOrder(order.id)).isErr, isTrue);

      // The delivery that was never recorded.
      await inventory.stockIn(
        inventoryItemId: cheese.id,
        quantityMilli: StockQuantity.parse('5'),
        reason: 'delivery recorded late',
      );

      final Result<OrderInventoryDeduction> retried = await deductions
          .deductForOrder(order.id);

      expect(retried.isOk, isTrue);
      expect(retried.valueOrNull!.status, InventoryDeductionStatus.deducted);
      expect(retried.valueOrNull!.attemptCount, 2);
      expect(await balanceOf(cheese), 5050 - 100);
      expect(await balanceOf(flour), 50000 - 150);
      // Off the operator's work list.
      expect((await deductions.loadFailedDeductions()).valueOrNull, isEmpty);
    });

    test(
      'a recipe using a deleted stock item fails rather than skipping',
      () async {
        // Deleting an item a recipe uses is refused, so this state is only reachable by
        // going round the repository. Reaching it must not silently deduct nothing and
        // call the bill done.
        final Order order = await sell(size: medium);
        await database.database.update(
          'inventory_items',
          <String, Object?>{'isDeleted': 1},
          where: 'id = ?',
          whereArgs: <Object?>[cheese.id],
        );

        final Result<OrderInventoryDeduction> result = await deductions
            .deductForOrder(order.id);

        expect(result.failureOrNull, isA<ValidationFailure>());
        expect(await balanceOf(flour), 50000);
      },
    );
  });

  group('idempotency', () {
    setUp(() async {
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );
    });

    test('deducting the same bill twice deducts once', () async {
      final Order order = await sell(size: medium);

      await deductions.deductForOrder(order.id);
      expect(await balanceOf(cheese), 20000 - 100);

      await deductions.deductForOrder(order.id);
      expect(await balanceOf(cheese), 20000 - 100);
    });

    test('a third and fourth attempt change nothing', () async {
      final Order order = await sell(size: medium);

      for (int attempt = 0; attempt < 4; attempt++) {
        final Result<OrderInventoryDeduction> result = await deductions
            .deductForOrder(order.id);
        expect(result.isOk, isTrue);
        expect(result.valueOrNull!.status, InventoryDeductionStatus.deducted);
      }

      expect(await balanceOf(cheese), 20000 - 100);
      expect(await saleMovementsFor(order), hasLength(1));
      // One record, not four.
      expect(await rowCount('order_inventory_deductions'), 1);
    });

    test('a retry returns the stored record untouched', () async {
      final Order order = await sell(size: medium);
      final OrderInventoryDeduction first = (await deductions.deductForOrder(
        order.id,
      )).valueOrNull!;

      final OrderInventoryDeduction second = (await deductions.deductForOrder(
        order.id,
      )).valueOrNull!;

      // Same row, same identity, and the attempt count is not inflated by a call that
      // did nothing.
      expect(second.id, first.id);
      expect(second.attemptCount, first.attemptCount);
      expect(second.movementCount, first.movementCount);
    });

    test('two different bills each deduct their own stock', () async {
      final Order first = await sell(size: medium);
      final Order second = await sell(size: medium);

      await deductions.deductForOrder(first.id);
      await deductions.deductForOrder(second.id);

      expect(await balanceOf(cheese), 20000 - 200);
      expect(await rowCount('order_inventory_deductions'), 2);
    });

    test('a bill that was never settled cannot be deducted', () async {
      final Result<OrderInventoryDeduction> result = await deductions
          .deductForOrder('ord-does-not-exist');

      expect(result.failureOrNull, isA<ValidationFailure>());
      // Nothing to attach a failure record to, so none is invented.
      expect(await rowCount('order_inventory_deductions'), 0);
    });
  });

  group('historical safety', () {
    setUp(() async {
      await configure(
        scope: productScope(),
        stockItem: cheese,
        quantity: '0.1',
      );
    });

    test('repricing the menu does not change the deduction', () async {
      final Order order = await sell(size: medium);

      await menu.saveVariant(medium.copyWith(price: Money.parse('999.00')));
      await menu.saveItem(pizza.copyWith(basePrice: Money.parse('888.00')));

      final OrderInventoryDeduction deduction =
          (await deductions.deductForOrder(order.id)).valueOrNull!;

      // Stock follows quantity sold, never price.
      expect(deduction.movementCount, 1);
      expect(await balanceOf(cheese), 20000 - 100);
    });

    test('renaming the menu item does not break the deduction', () async {
      final Order order = await sell(size: medium);

      await menu.saveItem(pizza.copyWith(name: 'Renamed After The Sale'));

      final Result<OrderInventoryDeduction> result = await deductions
          .deductForOrder(order.id);

      expect(result.isOk, isTrue);
      expect(await balanceOf(cheese), 20000 - 100);
    });

    test('the reported name is the one the customer was charged for', () async {
      // No recipe, so the line is reported. It must be reported under the name on the
      // bill, not whatever the product is called by the time an operator reads it.
      final MenuItem other = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem item) => item.name == 'Cheese & Onion',
      );
      final List<MenuItemVariant> sizes = (await menu.loadVariants(other.id))
          .valueOrNull!;

      final Cart cart = await SeededCart.cartOf(
        menu,
        category: 'SIMPLY VEG',
        item: 'Cheese & Onion',
        size: sizes.first.name,
      );
      final Order order = (await checkout.settle(
        BillSettlement.fromCart(
          cart: cart,
          orderType: OrderType.takeaway,
          paymentMethod: PaymentMethod.cash,
        ),
      )).valueOrNull!;

      await menu.saveItem(other.copyWith(name: 'Renamed Later'));

      final OrderInventoryDeduction deduction =
          (await deductions.deductForOrder(order.id)).valueOrNull!;

      expect(
        deduction.unconfiguredItems.single,
        'Cheese & Onion (${sizes.first.name})',
      );
    });

    test('deleting the menu item after the sale does not break it', () async {
      final Order order = await sell(size: medium);

      // Soft delete, as the menu repository does it. The recipe rows survive with it.
      await menu.deleteItem(pizza.id);

      final Result<OrderInventoryDeduction> result = await deductions
          .deductForOrder(order.id);

      expect(result.isOk, isTrue);
      expect(await balanceOf(cheese), 20000 - 100);
    });

    test(
      'changing a recipe cannot re-deduct an already processed bill',
      () async {
        final Order order = await sell(size: medium);
        await deductions.deductForOrder(order.id);
        expect(await balanceOf(cheese), 20000 - 100);

        // The recipe is corrected upwards afterwards. What came off the shelf is in the
        // ledger and is not recalculated.
        final List<Map<String, Object?>> line = await database.database.query(
          'recipe_ingredients',
          where: 'inventoryItemId = ?',
          whereArgs: <Object?>[cheese.id],
        );
        await recipes.updateIngredientQuantity(
          ingredientId: line.single['id']! as String,
          quantityMilli: StockQuantity.parse('0.5'),
        );

        await deductions.deductForOrder(order.id);

        expect(await balanceOf(cheese), 20000 - 100);
        expect(await saleMovementsFor(order), hasLength(1));
      },
    );

    test(
      'a recipe change applies to the next sale, not the last one',
      () async {
        final Order first = await sell(size: medium);
        await deductions.deductForOrder(first.id);

        final List<Map<String, Object?>> line = await database.database.query(
          'recipe_ingredients',
          where: 'inventoryItemId = ?',
          whereArgs: <Object?>[cheese.id],
        );
        await recipes.updateIngredientQuantity(
          ingredientId: line.single['id']! as String,
          quantityMilli: StockQuantity.parse('0.2'),
        );

        final Order second = await sell(size: medium);
        await deductions.deductForOrder(second.id);

        // 100 at the old recipe, 200 at the new one.
        expect(await balanceOf(cheese), 20000 - 300);
      },
    );

    test('a sale movement is stamped with the bill it came from', () async {
      final Order order = await sell(size: medium);
      await deductions.deductForOrder(order.id);

      final StockMovement sale = (await ledgerOf(cheese))
          .firstWhere((StockMovement m) => m.isSale);

      // The bill's instant, so a deduction retried later still sorts with the sale
      // that caused it. Compared in stored milliseconds, which is the precision the
      // schema keeps.
      expect(
        sale.createdAt.millisecondsSinceEpoch,
        order.createdAt.millisecondsSinceEpoch,
      );
    });
  });
}
