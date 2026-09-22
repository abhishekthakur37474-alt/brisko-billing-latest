import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_held_bill_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_draft.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_status.dart';
import 'package:brisko_billing/features/billing/presentation/screens/held_bills_screen.dart';
import 'package:brisko_billing/features/billing/presentation/widgets/cart_panel.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';
import '../helpers/unavailable_held_bill_repository.dart';

/// Holding and resuming driven through the real application.
///
/// ## Why the whole app rather than the screen alone
///
/// The held bills list is reached by a button on the billing cart and it changes the live
/// cart, which lives above the shell. Both of those are wiring, and wiring is exactly what
/// a widget test should exercise. So these tests build `BriskoApp` over a real in-memory
/// database, tap their way to the list, and read what is on screen.
///
/// Every error path asserts `tester.takeException()` is null, because a failure that
/// arrives as a rendered message is a handled failure and one that arrives as an exception
/// through the widget tree is not.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteHeldBillRepository held;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    held = SqliteHeldBillRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// Lets in-flight database work finish, then renders the result.
  ///
  /// A widget test body runs inside a fake-async zone where real I/O never completes, and
  /// sqflite answers from outside it. Bounded pumps interleaved with
  /// [WidgetTester.runAsync] rather than `pumpAndSettle`, which would never settle while a
  /// progress indicator is spinning.
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

  /// Builds the app on a counter-sized display, on the billing screen.
  Future<void> openBilling(
    WidgetTester tester, {
    AppDependencies? dependencies,
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      BriskoApp(dependencies: dependencies ?? TestDependencies.over(database)),
    );
    await settleUi(tester);
    await tap(tester, find.text(PosSection.billing.label));
  }

  /// Opens the held bills list through the button on the cart.
  Future<void> openHeldBills(
    WidgetTester tester, {
    AppDependencies? dependencies,
  }) async {
    await openBilling(tester, dependencies: dependencies);
    await tap(tester, find.widgetWithText(TextButton, 'Held bills'));
  }

  /// Rings up one Medium Cheese Pizza through the real menu: 250.
  ///
  /// The size chip reads `Medium  ₹250.00` and the add button `Add to bill`, so both are
  /// matched by substring rather than by exact text.
  Future<void> ringUpPizza(WidgetTester tester) async {
    await tap(tester, find.text('Cheese Pizza').first);
    await tap(tester, find.textContaining('Medium').first);
    await tap(tester, find.widgetWithText(FilledButton, 'Add to bill').first);
  }

  /// Holds one pizza directly, so a list test does not depend on the hold UI.
  ///
  /// The seeding and the write are real database work, and a widget test body runs inside a
  /// fake-async zone where real I/O never completes on its own. So it runs through
  /// [WidgetTester.runAsync], the same way every other screen test seeds its data from
  /// inside a test body.
  Future<HeldBill> holdOnePizza(
    WidgetTester tester, {
    OrderType orderType = OrderType.takeaway,
    String? customerPhone,
    int quantity = 1,
  }) async {
    final HeldBill? record = await tester.runAsync<HeldBill>(() async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        menu,
        quantity: quantity,
      );
      return (await held.hold(
        HeldBillDraft.fromCart(
          cart: cart,
          orderType: orderType,
          customerPhone: customerPhone,
        ),
      )).valueOrNull!;
    });
    return record!;
  }

  group('the empty state', () {
    testWidgets('says nothing is being held rather than showing a blank list', (
      WidgetTester tester,
    ) async {
      await openHeldBills(tester);

      expect(find.text('Held bills'), findsWidgets);
      expect(find.text('No bills are being held'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Resume'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the list', () {
    testWidgets('shows the time, the counts, the customer and the total', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(
        tester,
        orderType: OrderType.delivery,
        customerPhone: '9000000001',
        quantity: 2,
      );

      await openHeldBills(tester);

      expect(find.text('1 line \u00b7 2 items'), findsOneWidget);
      expect(find.text('Customer 90000 00001'), findsOneWidget);
      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('\u20b9640.00'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a walk-in bill says so', (WidgetTester tester) async {
      await holdOnePizza(tester);

      await openHeldBills(tester);

      expect(find.text('Walk-in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two held bills are both listed', (WidgetTester tester) async {
      await holdOnePizza(tester);
      await holdOnePizza(tester, quantity: 3);

      await openHeldBills(tester);

      expect(find.widgetWithText(FilledButton, 'Resume'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('holding from the cart', () {
    testWidgets('the Hold button is disabled on an empty bill', (
      WidgetTester tester,
    ) async {
      await openBilling(tester);

      final Finder hold = find.widgetWithText(TextButton, 'Hold');
      expect(hold, findsOneWidget);
      expect(tester.widget<TextButton>(hold).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('holding a bill confirms it and empties the cart', (
      WidgetTester tester,
    ) async {
      await openBilling(tester);
      await ringUpPizza(tester);
      expect(find.text('\u20b9250.00'), findsWidgets);

      await tap(tester, find.widgetWithText(TextButton, 'Hold'));

      // The confirmation names what was put aside, after the cart it describes has gone.
      expect(find.textContaining('Bill held'), findsOneWidget);
      expect(find.textContaining('1 line'), findsWidgets);
      expect(find.text('No items yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the held bill then appears in the list', (
      WidgetTester tester,
    ) async {
      await openBilling(tester);
      await ringUpPizza(tester);
      await tap(tester, find.widgetWithText(TextButton, 'Hold'));

      await tap(tester, find.widgetWithText(TextButton, 'Held bills'));

      expect(find.text('No bills are being held'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the confirmation can be dismissed', (
      WidgetTester tester,
    ) async {
      await openBilling(tester);
      await ringUpPizza(tester);
      await tap(tester, find.widgetWithText(TextButton, 'Hold'));
      expect(find.textContaining('Bill held'), findsOneWidget);

      await tap(tester, find.widgetWithIcon(IconButton, Icons.close).first);

      // The confirmation is gone, and nothing was thrown dismissing it.
      expect(find.textContaining('Bill held'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hold that fails is reported and keeps the bill', (
      WidgetTester tester,
    ) async {
      await openBilling(
        tester,
        dependencies: TestDependencies.over(
          database,
          heldBillRepository: const UnavailableHeldBillRepository(),
        ),
      );
      await ringUpPizza(tester);

      await tap(tester, find.widgetWithText(TextButton, 'Hold'));

      expect(find.text(UnavailableHeldBillRepository.message), findsOneWidget);
      // The bill is still on screen and still sellable.
      expect(find.text('No items yet'), findsNothing);
      expect(find.textContaining('Bill held'), findsNothing);
      expect(find.textContaining('Checkout'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing was written when the hold failed', (
      WidgetTester tester,
    ) async {
      await openBilling(
        tester,
        dependencies: TestDependencies.over(
          database,
          heldBillRepository: const UnavailableHeldBillRepository(),
        ),
      );
      await ringUpPizza(tester);
      await tap(tester, find.widgetWithText(TextButton, 'Hold'));

      await tester.runAsync(() async {
        expect(await database.database.query(SqliteTables.heldBills), isEmpty);
      });
      expect(tester.takeException(), isNull);
    });
  });

  group('resuming', () {
    testWidgets('takes the bill into the cart and returns to billing', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester, quantity: 2);
      await openHeldBills(tester);

      await tap(tester, find.widgetWithText(FilledButton, 'Resume'));

      // Back on the billing screen, with the held bill in the cart.
      expect(find.byType(CartPanel), findsOneWidget);
      expect(find.text('No items yet'), findsNothing);
      expect(find.textContaining('\u20b9640.00'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the resumed bill can be taken to checkout', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester);
      await openHeldBills(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Resume'));

      await tap(tester, find.textContaining('Checkout'));

      // The existing settlement flow opens on the resumed bill.
      expect(find.text('Review bill'), findsOneWidget);
      expect(find.textContaining('Take payment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bill leaves the list once resumed', (
      WidgetTester tester,
    ) async {
      final HeldBill record = await holdOnePizza(tester);
      await openHeldBills(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Resume'));

      await tester.runAsync(() async {
        expect(
          (await held.findHeldBill(record.id)).valueOrNull!.status,
          HeldBillStatus.resumed,
        );
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets('Resume is disabled while a bill is already on screen', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester);
      await openBilling(tester);
      await ringUpPizza(tester);

      await tap(tester, find.widgetWithText(TextButton, 'Held bills'));

      final Finder resume = find.widgetWithText(FilledButton, 'Resume');
      expect(resume, findsOneWidget);
      expect(tester.widget<FilledButton>(resume).onPressed, isNull);
      // And the reason is on screen rather than left to be guessed at.
      expect(
        find.textContaining('Hold or clear the bill on screen'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a resume that fails is reported without an exception', (
      WidgetTester tester,
    ) async {
      final HeldBill record = await holdOnePizza(tester);
      await openHeldBills(tester);

      // Cancelled behind the screen's back, which is what a second terminal looks like.
      await tester.runAsync(() async {
        await held.cancel(record.id);
      });

      await tap(tester, find.widgetWithText(FilledButton, 'Resume'));

      // The list reloaded and the bill is gone. Nothing was thrown.
      expect(find.text('No bills are being held'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('cancelling a held bill', () {
    testWidgets('asks first, and keeping it changes nothing', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester);
      await openHeldBills(tester);

      await tap(tester, find.widgetWithText(TextButton, 'Cancel'));
      expect(find.text('Cancel this held bill?'), findsOneWidget);
      await tap(tester, find.widgetWithText(TextButton, 'Keep it'));

      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('confirming removes it from the list', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester);
      await openHeldBills(tester);

      await tap(tester, find.widgetWithText(TextButton, 'Cancel'));
      await tap(tester, find.widgetWithText(FilledButton, 'Cancel the bill'));

      expect(find.text('No bills are being held'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no sale is created by cancelling', (
      WidgetTester tester,
    ) async {
      await holdOnePizza(tester);
      await openHeldBills(tester);
      await tap(tester, find.widgetWithText(TextButton, 'Cancel'));
      await tap(tester, find.widgetWithText(FilledButton, 'Cancel the bill'));

      await tester.runAsync(() async {
        expect(await database.database.query(SqliteTables.orders), isEmpty);
        expect(await database.database.query(SqliteTables.payments), isEmpty);
        expect(
          await database.database.query(SqliteTables.stockMovements),
          isEmpty,
        );
      });
      expect(tester.takeException(), isNull);
    });
  });

  group('a repository that cannot be read', () {
    testWidgets('renders the retry rather than throwing', (
      WidgetTester tester,
    ) async {
      await openHeldBills(
        tester,
        dependencies: TestDependencies.over(
          database,
          heldBillRepository: const UnavailableHeldBillRepository(),
        ),
      );

      expect(find.text('The held bills could not be loaded'), findsOneWidget);
      expect(find.text(UnavailableHeldBillRepository.message), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      // The whole point of the group.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the retry can be pressed without throwing', (
      WidgetTester tester,
    ) async {
      await openHeldBills(
        tester,
        dependencies: TestDependencies.over(
          database,
          heldBillRepository: const UnavailableHeldBillRepository(),
        ),
      );

      await tap(tester, find.widgetWithText(FilledButton, 'Try again'));

      // Still failing, still rendered, still nothing thrown.
      expect(find.text('The held bills could not be loaded'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the error names the held bills rather than the menu', (
      WidgetTester tester,
    ) async {
      await openHeldBills(
        tester,
        dependencies: TestDependencies.over(
          database,
          heldBillRepository: const UnavailableHeldBillRepository(),
        ),
      );

      // Sending a cashier to look at the menu would waste their time.
      expect(find.text('The menu could not be loaded'), findsNothing);
      expect(find.byType(HeldBillsErrorView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
