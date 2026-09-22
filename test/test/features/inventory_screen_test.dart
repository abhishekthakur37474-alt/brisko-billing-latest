import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement_type.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_quantity.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/recipe_repository.dart';
import 'package:brisko_billing/features/inventory/presentation/screens/inventory_screen.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/repositories/menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

/// The inventory screen driven by tapping, over the real database.
///
/// Nothing is stubbed and no sample stock is injected, so an assertion about what is on
/// screen is an assertion about what is stored.
///
/// ## Why database work goes through [WidgetTester.runAsync]
///
/// A widget test runs its body inside a fake-async zone, where the clock is controlled
/// and real I/O never completes. sqflite answers from outside that zone, so a query
/// awaited directly in a test body would hang forever. Every database call here is
/// therefore wrapped, which also makes the boundary between "arrange the stored data"
/// and "drive the widgets" explicit.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteInventoryRepository inventory;
  late SqliteRecipeRepository recipes;
  late SqliteInventoryDeductionRepository deductions;
  late SqliteCheckoutRepository checkout;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    recipes = SqliteRecipeRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
    final T? value = await tester.runAsync<T>(action);
    return value as T;
  }

  /// Lets in-flight database work finish, then renders the result.
  ///
  /// Bounded pumps rather than `pumpAndSettle`. The forms on this screen autofocus a
  /// text field, and a focused field blinks its caret on a repeating timer, so the
  /// widget tree is never quiescent and `pumpAndSettle` would run until it gave up.
  /// Alternating between real time, for the database, and pumped frames, for the
  /// animations, covers well over the longest transition here.
  Future<void> settleUi(WidgetTester tester) async {
    for (int round = 0; round < 8; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await settleUi(tester);
  }

  Future<void> enter(WidgetTester tester, String label, String value) async {
    await tester.enterText(
      find.ancestor(of: find.text(label), matching: find.byType(TextField)),
      value,
    );
    await tester.pump();
  }

  Future<InventoryItem> addStockItem(
    WidgetTester tester, {
    String name = 'Test Flour',
    String currentQuantity = '10',
    String minimumQuantity = '2',
  }) {
    return real<InventoryItem>(tester, () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: name,
        currentQuantity: currentQuantity,
        minimumQuantity: minimumQuantity,
      );
      await inventory.saveItem(item);
      return item;
    });
  }

  Future<InventoryItem> reload(WidgetTester tester, InventoryItem item) => real(
    tester,
    () async => (await inventory.findItem(item.id)).valueOrNull!,
  );

  Future<List<StockMovement>> ledgerOf(
    WidgetTester tester,
    InventoryItem item,
  ) => real(
    tester,
    () async => (await inventory.loadMovements(item.id)).valueOrNull!,
  );

  Future<void> runSql(WidgetTester tester, String statement) =>
      real<void>(tester, () => database.database.execute(statement));

  /// A finder narrowed to the open dialog.
  ///
  /// Several labels appear both on the list behind and on the form in front — "Add
  /// item" and "Stock in" among them — so a form assertion says which one it means.
  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);

  /// The overflow menu on one item's row.
  ///
  /// Found by its tooltip rather than by widget type, because the menu is generic over
  /// a private action enum that a test cannot name.
  Finder moreActions(String itemName) =>
      find.byTooltip('More actions for $itemName');

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<InventoryRepository>.value(value: inventory),
          Provider<RecipeRepository>.value(value: recipes),
          Provider<InventoryDeductionRepository>.value(value: deductions),
          Provider<MenuRepository>.value(value: menu),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: InventoryScreen()),
        ),
      ),
    );
    await settleUi(tester);
  }

  group('the stock list', () {
    testWidgets('an outlet with no stock items says so honestly', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);

      expect(find.text('No stock items yet'), findsOneWidget);
      expect(find.text('Add the first item'), findsOneWidget);
      // No sample row, no spinner left running, no error.
      expect(find.byType(Card), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a stored item renders with its balance and threshold', (
      WidgetTester tester,
    ) async {
      await addStockItem(
        tester,
        name: 'Test Flour',
        currentQuantity: '12.5',
        minimumQuantity: '3',
      );

      await pumpScreen(tester);

      expect(find.text('Test Flour'), findsOneWidget);
      expect(find.text('12.5 kg'), findsOneWidget);
      expect(find.text('Low below 3 kg'), findsOneWidget);
      expect(find.text('No stock items yet'), findsNothing);
    });

    testWidgets('an unmonitored item says it is not monitored', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester, currentQuantity: '5', minimumQuantity: '0');

      await pumpScreen(tester);

      expect(find.text('Not monitored'), findsOneWidget);
      expect(find.text('Low'), findsNothing);
    });

    testWidgets('a low item is flagged in words, not only in colour', (
      WidgetTester tester,
    ) async {
      await addStockItem(
        tester,
        name: 'Test Low',
        currentQuantity: '1',
        minimumQuantity: '2',
      );
      await addStockItem(
        tester,
        name: 'Test Healthy',
        currentQuantity: '50',
        minimumQuantity: '2',
      );

      await pumpScreen(tester);

      expect(find.text('Low'), findsOneWidget);
      expect(find.text('1 low'), findsOneWidget);
    });
  });

  group('adding an item', () {
    testWidgets('the form creates an item at a zero balance', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);

      await tap(tester, find.text('Add the first item'));
      await enter(tester, 'Name', 'Test Tomato Sauce');
      await enter(tester, 'Low stock threshold (kg)', '2');
      await tap(tester, inDialog(find.text('Add item')));

      expect(find.text('Test Tomato Sauce'), findsOneWidget);
      // Zero on purpose: what is on the shelf arrives through the ledger.
      expect(find.text('0 kg'), findsOneWidget);
      expect(find.text('Low below 2 kg'), findsOneWidget);
    });

    testWidgets('a blank name is refused without an exception', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);

      await tap(tester, find.text('Add the first item'));
      await tap(tester, inDialog(find.text('Add item')));

      expect(find.text('Give the item a name.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Still on the form, so nothing the operator typed is lost, and nothing was
      // created behind it.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        await real(
          tester,
          () async => (await inventory.loadItems()).valueOrNull!,
        ),
        isEmpty,
      );
    });

    testWidgets('a threshold that is not a number is refused', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);

      await tap(tester, find.text('Add the first item'));
      await enter(tester, 'Name', 'Test Item');
      await enter(tester, 'Low stock threshold (kg)', 'two kilos');
      await tap(tester, inDialog(find.text('Add item')));

      expect(find.textContaining('Enter the threshold'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('recording stock in', () {
    testWidgets('it raises the balance and writes a movement', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        currentQuantity: '10',
      );
      await pumpScreen(tester);

      await tap(tester, find.text('Stock in').first);
      await enter(tester, 'Quantity received (kg)', '5.5');
      await enter(tester, 'Reason', 'test delivery');
      await tap(tester, inDialog(find.text('Record stock in')));

      expect(find.text('15.5 kg'), findsOneWidget);
      expect((await reload(tester, item)).currentQuantityMilli, 15500);

      final List<StockMovement> ledger = await ledgerOf(tester, item);
      expect(ledger, hasLength(1));
      expect(ledger.single.movementType, StockMovementType.stockIn);
      expect(ledger.single.reason, 'test delivery');
    });

    testWidgets('a quantity that is not a number is refused', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(tester);
      await pumpScreen(tester);

      await tap(tester, find.text('Stock in').first);
      await enter(tester, 'Quantity received (kg)', 'a lot');
      await tap(tester, inDialog(find.text('Record stock in')));

      expect(find.textContaining('Enter the quantity'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(await ledgerOf(tester, item), isEmpty);
    });
  });

  group('recording wastage', () {
    testWidgets('it lowers the balance and can push an item into low stock', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        currentQuantity: '5',
        minimumQuantity: '2',
      );
      await pumpScreen(tester);

      await tap(tester, moreActions('Test Flour'));
      await tap(tester, find.text('Record wastage'));
      await enter(tester, 'Quantity wasted (kg)', '3.5');
      await enter(tester, 'Reason', 'spoiled');
      await tap(tester, inDialog(find.text('Record wastage')));

      expect(find.text('1.5 kg'), findsOneWidget);
      expect(find.text('Low'), findsOneWidget);

      final List<StockMovement> ledger = await ledgerOf(tester, item);
      expect(ledger.single.movementType, StockMovementType.wastage);
      expect(ledger.single.signedQuantityMilli, -3500);
    });

    testWidgets('wasting more than the shelf holds is refused on screen', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        name: 'Test Flour',
        currentQuantity: '2',
      );
      await pumpScreen(tester);

      await tap(tester, moreActions('Test Flour'));
      await tap(tester, find.text('Record wastage'));
      await enter(tester, 'Quantity wasted (kg)', '99');
      await tap(tester, inDialog(find.text('Record wastage')));

      expect(find.textContaining('Not enough Test Flour'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Nothing applied, and the balance is untouched.
      expect((await reload(tester, item)).currentQuantityMilli, 2000);
      expect(await ledgerOf(tester, item), isEmpty);
    });
  });

  group('recording an adjustment', () {
    testWidgets('it can correct a balance downwards', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        currentQuantity: '10',
      );
      await pumpScreen(tester);

      await tap(tester, moreActions('Test Flour'));
      await tap(tester, find.text('Adjustment'));
      await tap(tester, find.text('Remove'));
      await enter(tester, 'Correction, positive or negative (kg)', '1.25');
      await tap(tester, inDialog(find.text('Record adjustment')));

      expect(find.text('8.75 kg'), findsOneWidget);

      final List<StockMovement> ledger = await ledgerOf(tester, item);
      expect(ledger.single.movementType, StockMovementType.adjustment);
      expect(ledger.single.signedQuantityMilli, -1250);
    });
  });

  group('the history', () {
    testWidgets('it lists movements with their reasons', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        currentQuantity: '0',
      );
      await real<void>(tester, () async {
        await inventory.stockIn(
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('10'),
          reason: 'opening stock',
        );
        await inventory.recordWastage(
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('0.5'),
          reason: 'dropped',
        );
      });

      await pumpScreen(tester);
      await tap(tester, moreActions('Test Flour'));
      await tap(tester, find.text('View history'));

      expect(find.text('Test Flour history'), findsOneWidget);
      expect(inDialog(find.text('Stock in')), findsOneWidget);
      expect(inDialog(find.text('+10 kg')), findsOneWidget);
      expect(inDialog(find.text('opening stock')), findsOneWidget);
      expect(inDialog(find.text('Wastage')), findsOneWidget);
      expect(inDialog(find.text('-0.5 kg')), findsOneWidget);
      expect(inDialog(find.text('dropped')), findsOneWidget);
    });

    testWidgets('an item that has never moved shows an empty ledger', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester, currentQuantity: '0');
      await pumpScreen(tester);

      await tap(tester, moreActions('Test Flour'));
      await tap(tester, find.text('View history'));

      expect(find.text('No movements yet'), findsOneWidget);
    });

    testWidgets('a sale deduction is identifiable by its bill', (
      WidgetTester tester,
    ) async {
      final InventoryItem item = await addStockItem(
        tester,
        name: 'Test Cheese',
        currentQuantity: '10',
      );
      final Order order = await real<Order>(tester, () async {
        final MenuItem pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
          (MenuItem candidate) => candidate.name == 'Cheese Pizza',
        );
        await recipes.addIngredient(
          scope: RecipeScope.product(pizza.id),
          inventoryItemId: item.id,
          quantityMilli: StockQuantity.parse('0.1'),
        );

        final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
          menu,
        );
        final Order settled = (await checkout.settle(
          BillSettlement.fromCart(
            cart: cart,
            orderType: OrderType.takeaway,
            paymentMethod: PaymentMethod.cash,
          ),
        )).valueOrNull!;
        await deductions.deductForOrder(settled.id);
        return settled;
      });

      await pumpScreen(tester);
      await tap(tester, moreActions('Test Cheese'));
      await tap(tester, find.text('View history'));

      expect(inDialog(find.text('Sale')), findsOneWidget);
      expect(inDialog(find.text('-0.1 kg')), findsOneWidget);
      expect(inDialog(find.text('Bill ${order.id}')), findsOneWidget);
    });
  });

  group('bills whose stock was not deducted', () {
    /// Settles a pizza whose recipe needs more cheese than the shelf holds.
    Future<Order> sellBeyondStock(WidgetTester tester) {
      return real<Order>(tester, () async {
        final InventoryItem cheese = Fixtures.inventoryItem(
          name: 'Test Cheese',
          currentQuantity: '0',
          minimumQuantity: '0',
        );
        await inventory.saveItem(cheese);

        final MenuItem pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
          (MenuItem candidate) => candidate.name == 'Cheese Pizza',
        );
        await recipes.addIngredient(
          scope: RecipeScope.product(pizza.id),
          inventoryItemId: cheese.id,
          quantityMilli: StockQuantity.parse('0.1'),
        );

        final Order settled = (await checkout.settle(
          BillSettlement.fromCart(
            cart: await SeededCart.mediumCheesePizzaWithExtraCheese(menu),
            orderType: OrderType.takeaway,
            paymentMethod: PaymentMethod.cash,
          ),
        )).valueOrNull!;
        await deductions.deductForOrder(settled.id);
        return settled;
      });
    }

    testWidgets('they are listed with the reason and a retry', (
      WidgetTester tester,
    ) async {
      final Order order = await sellBeyondStock(tester);

      await pumpScreen(tester);

      expect(
        find.text('Stock not deducted for 1 settled bill'),
        findsOneWidget,
      );
      expect(find.text('Bill ${order.orderNumber}'), findsOneWidget);
      expect(find.textContaining('Not enough Test Cheese'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('retrying after the stock is corrected clears the list', (
      WidgetTester tester,
    ) async {
      await sellBeyondStock(tester);
      await pumpScreen(tester);
      expect(find.text('Retry'), findsOneWidget);

      // The delivery that was never recorded.
      await tap(tester, find.text('Stock in').first);
      await enter(tester, 'Quantity received (kg)', '5');
      await tap(tester, inDialog(find.text('Record stock in')));

      await tap(tester, find.text('Retry'));

      expect(find.text('Retry'), findsNothing);
      expect(find.textContaining('Stock not deducted'), findsNothing);
      // 5 kg received less the 100 g the bill owed.
      expect(find.text('4.9 kg'), findsOneWidget);
    });

    testWidgets('an item sold with no recipe is named for the operator', (
      WidgetTester tester,
    ) async {
      await real<void>(tester, () async {
        final Order settled = (await checkout.settle(
          BillSettlement.fromCart(
            cart: await SeededCart.mediumCheesePizzaWithExtraCheese(menu),
            orderType: OrderType.takeaway,
            paymentMethod: PaymentMethod.cash,
          ),
        )).valueOrNull!;
        await deductions.deductForOrder(settled.id);
      });
      await addStockItem(tester);

      await pumpScreen(tester);

      expect(find.text('Recipe not configured'), findsOneWidget);
      expect(find.textContaining('Cheese Pizza (Medium)'), findsOneWidget);
    });
  });

  group('a storage failure', () {
    testWidgets('is rendered as a notice rather than thrown at the widget', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await runSql(
        tester,
        'ALTER TABLE inventory_items RENAME TO inventory_items_moved',
      );

      await pumpScreen(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('stock items'), findsWidgets);
      expect(find.text('Try again'), findsOneWidget);
      // No half-rendered list beside the notice.
      expect(find.text('Test Flour'), findsNothing);
    });

    testWidgets('can be dismissed, and retried once the fault is gone', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await runSql(
        tester,
        'ALTER TABLE inventory_items RENAME TO inventory_items_moved',
      );

      await pumpScreen(tester);
      expect(find.text('Try again'), findsOneWidget);

      await tap(tester, find.byTooltip('Dismiss'));
      expect(find.text('Try again'), findsNothing);

      await runSql(
        tester,
        'ALTER TABLE inventory_items_moved RENAME TO inventory_items',
      );
      await tap(tester, find.text('Refresh'));

      expect(tester.takeException(), isNull);
      expect(find.text('Test Flour'), findsOneWidget);
    });
  });

  group('navigation', () {
    testWidgets('the screen is reachable from the POS navigation', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await addStockItem(tester, name: 'Test Flour');
      final AppDependencies dependencies = TestDependencies.over(database);

      await tester.pumpWidget(BriskoApp(dependencies: dependencies));
      await settleUi(tester);

      await tap(tester, find.text(PosSection.inventory.label));

      expect(find.text('Stock items'), findsOneWidget);
      expect(find.text('Test Flour'), findsOneWidget);
      // The placeholder is gone for good.
      expect(find.text('Not implemented yet.'), findsNothing);
    });
  });
}
