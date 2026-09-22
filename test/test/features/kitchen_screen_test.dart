import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/kot/domain/repositories/kot_repository.dart';
import 'package:brisko_billing/features/kot/presentation/screens/kitchen_screen.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

/// The kitchen board driven by tapping, over the real database and seeded menu.
///
/// Every slip on screen was raised by a real settlement through the real checkout
/// transaction. Nothing is stubbed and no sample slip is injected, so an assertion
/// about what the kitchen reads is an assertion about what was actually stored.
///
/// ## Why database work goes through [WidgetTester.runAsync]
///
/// A widget test runs its body inside a fake-async zone, where the clock is
/// controlled and real I/O never completes. sqflite answers from outside that zone,
/// so a query awaited directly in a test body would hang forever. Every database call
/// here is therefore wrapped, which also makes the boundary between "arrange the
/// stored data" and "drive the widgets" explicit.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteKotRepository kots;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    kots = SqliteKotRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// Runs [action] against the real database, outside the fake-async zone.
  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
    final T? value = await tester.runAsync<T>(action);
    return value as T;
  }

  /// Lets in-flight database work finish, then renders the result.
  Future<void> settleUi(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await settleUi(tester);
  }

  /// Settles a Medium Cheese Pizza with Extra Cheese, ×[quantity].
  Future<Order> sellPizza(
    WidgetTester tester, {
    int quantity = 1,
    OrderType orderType = OrderType.takeaway,
  }) {
    return real<Order>(tester, () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        menu,
        quantity: quantity,
      );
      return (await checkout.settle(
        BillSettlement.fromCart(
          cart: cart,
          orderType: orderType,
          paymentMethod: PaymentMethod.cash,
        ),
      )).valueOrNull!;
    });
  }

  /// The board as it is actually stored, read outside the widgets.
  Future<List<KitchenTicket>> storedBoard(WidgetTester tester) =>
      real(tester, () async => (await kots.loadActiveTickets()).valueOrNull!);

  Future<void> runSql(WidgetTester tester, String statement) =>
      real<void>(tester, () => database.database.execute(statement));

  Future<void> pumpBoard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [Provider<KotRepository>.value(value: kots)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: KitchenScreen()),
        ),
      ),
    );
    await settleUi(tester);
  }

  /// The card for [order], so an assertion cannot be satisfied by another slip.
  Finder inCard(Order order, Finder matching) => find.descendant(
    of: find.ancestor(
      of: find.text(order.orderNumber),
      matching: find.byType(Card),
    ),
    matching: matching,
  );

  group('loading the board', () {
    testWidgets('a settled bill appears as a slip the kitchen can read', (
      WidgetTester tester,
    ) async {
      final Order order = await sellPizza(tester, quantity: 2);

      await pumpBoard(tester);

      expect(find.text(order.orderNumber), findsOneWidget);
      expect(inCard(order, find.text('Cheese Pizza (Medium)')), findsOneWidget);
      expect(inCard(order, find.text('Extra Cheese')), findsOneWidget);
      expect(inCard(order, find.text('\u00d72')), findsOneWidget);
      expect(inCard(order, find.text('Takeaway')), findsOneWidget);
      // Its own slip number, alongside the order number.
      expect(
        inCard(order, find.textContaining(RegExp(r'^K\d{8}-0001$'))),
        findsOneWidget,
      );
    });

    testWidgets('the order type is shown, so the food is plated right', (
      WidgetTester tester,
    ) async {
      final Order order = await sellPizza(
        tester,
        orderType: OrderType.delivery,
      );

      await pumpBoard(tester);

      expect(inCard(order, find.text('Delivery')), findsOneWidget);
    });

    testWidgets('a new slip sits in the pending column', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester);

      await pumpBoard(tester);

      expect(find.text(KotStatus.pending.label), findsOneWidget);
      expect(find.text('Start preparing'), findsOneWidget);
      // Nothing has been cooked, so neither later column offers an action.
      expect(find.text('Mark ready'), findsNothing);
    });

    testWidgets('an outlet that has sold nothing sees an empty board', (
      WidgetTester tester,
    ) async {
      await pumpBoard(tester);

      expect(find.text('No kitchen slips'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      // Not a loading state left spinning, and not an error.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('refreshing picks up a bill settled since it was opened', (
      WidgetTester tester,
    ) async {
      await pumpBoard(tester);
      expect(find.text('No kitchen slips'), findsOneWidget);

      final Order order = await sellPizza(tester);
      await tap(tester, find.text('Refresh'));

      expect(find.text('No kitchen slips'), findsNothing);
      expect(find.text(order.orderNumber), findsOneWidget);
    });

    testWidgets('the board is reachable from the POS navigation', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final AppDependencies dependencies = _dependenciesOver(database);
      final Order order = await real<Order>(tester, () async {
        return (await dependencies.checkoutRepository.settle(
          BillSettlement.fromCart(
            cart: await SeededCart.mediumCheesePizzaWithExtraCheese(
              dependencies.menuRepository,
            ),
            orderType: OrderType.dineIn,
            paymentMethod: PaymentMethod.cash,
          ),
        )).valueOrNull!;
      });

      await tester.pumpWidget(BriskoApp(dependencies: dependencies));
      await settleUi(tester);

      await tap(tester, find.text(PosSection.orders.label));

      expect(find.text('Kitchen slips'), findsOneWidget);
      expect(find.text(order.orderNumber), findsOneWidget);
      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);
    });
  });

  group('moving a slip along', () {
    testWidgets('pending becomes preparing, then ready', (
      WidgetTester tester,
    ) async {
      final Order order = await sellPizza(tester);
      await pumpBoard(tester);

      await tap(tester, find.text('Start preparing'));

      expect(inCard(order, find.text('Mark ready')), findsOneWidget);
      expect(find.text('Start preparing'), findsNothing);
      expect((await storedBoard(tester)).single.status, KotStatus.preparing);

      await tap(tester, find.text('Mark ready'));

      // Ready is the end of the kitchen's workflow: no further action is offered.
      expect(inCard(order, find.byType(FilledButton)), findsNothing);
      expect((await storedBoard(tester)).single.status, KotStatus.ready);
      // Still on the board, waiting to be handed over.
      expect(find.text(order.orderNumber), findsOneWidget);
    });

    testWidgets('one slip moving leaves the others where they were', (
      WidgetTester tester,
    ) async {
      final Order first = await sellPizza(tester);
      final Order second = await sellPizza(tester);

      await pumpBoard(tester);
      await tap(tester, inCard(first, find.text('Start preparing')));

      expect(inCard(first, find.text('Mark ready')), findsOneWidget);
      expect(inCard(second, find.text('Start preparing')), findsOneWidget);
    });

    testWidgets('a move the workflow forbids is reported on screen', (
      WidgetTester tester,
    ) async {
      final Order order = await sellPizza(tester);
      await pumpBoard(tester);

      // The slip is advanced elsewhere while this board is open, so the card on
      // screen is stale and its button would repeat a move already made.
      final KitchenTicket ticket = (await storedBoard(tester)).single;
      await real<void>(
        tester,
        () => kots.advanceStatus(ticket.id, KotStatus.preparing),
      );

      await tap(tester, find.text('Start preparing'));

      expect(
        find.textContaining('cannot be moved to preparing'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // Refused, not applied twice.
      expect((await storedBoard(tester)).single.status, KotStatus.preparing);
      expect(find.text(order.orderNumber), findsOneWidget);
    });
  });

  group('a storage failure', () {
    testWidgets('is rendered as a notice rather than thrown at the widget', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester);
      // The board's own table is not where it should be: a storage fault the screen
      // cannot prevent and must not crash on.
      await runSql(
        tester,
        'ALTER TABLE kot_records RENAME TO kot_records_moved',
      );

      await pumpBoard(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('kitchen board'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      // No half-rendered board beside the notice.
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('can be dismissed, and retried once the fault is gone', (
      WidgetTester tester,
    ) async {
      final Order order = await sellPizza(tester);
      await runSql(
        tester,
        'ALTER TABLE kot_records RENAME TO kot_records_moved',
      );

      await pumpBoard(tester);
      expect(find.text('Try again'), findsOneWidget);

      await tap(tester, find.byTooltip('Dismiss'));
      expect(find.text('Try again'), findsNothing);

      await runSql(
        tester,
        'ALTER TABLE kot_records_moved RENAME TO kot_records',
      );
      await tap(tester, find.text('Refresh'));

      expect(tester.takeException(), isNull);
      expect(find.text(order.orderNumber), findsOneWidget);
    });
  });
}

/// The application dependency graph over an already-open test database.
AppDependencies _dependenciesOver(SqliteDatabase database) =>
    TestDependencies.over(database);
