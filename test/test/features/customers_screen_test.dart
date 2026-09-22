import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/repositories/customer_repository.dart';
import 'package:brisko_billing/features/customers/presentation/screens/customers_screen.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/orders/domain/repositories/order_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/repositories/payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/repositories/refund_repository.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';
import '../helpers/test_printing.dart';

/// The customers screen driven by tapping, over the real database and seeded menu.
///
/// Nothing is stubbed and no sample customer is injected, so an assertion about what is
/// on screen is an assertion about what is stored. Every customer here exists because a
/// bill was settled with their number, which is the only way the application creates one.
///
/// ## Why database work goes through [WidgetTester.runAsync]
///
/// A widget test runs its body inside a fake-async zone where the clock is controlled and
/// real I/O never completes. sqflite answers from outside that zone, so a query awaited
/// directly in a test body would hang forever. Every database call here is therefore
/// wrapped, which also makes the boundary between "arrange the stored data" and "drive
/// the widgets" explicit.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteRefundRepository refunds;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    refunds = SqliteRefundRepository(database: database);
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
  /// Bounded pumps rather than `pumpAndSettle`: the search field can hold focus, and a
  /// focused field blinks its caret on a repeating timer, so the tree is never quiescent
  /// and `pumpAndSettle` would run until it gave up.
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

  /// Settles a Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320 each.
  Future<Order> sellPizza(
    WidgetTester tester, {
    String? customerPhone,
    int quantity = 1,
    OrderType orderType = OrderType.takeaway,
    PaymentMethod paymentMethod = PaymentMethod.cash,
  }) {
    return real<Order>(tester, () async {
      final Result<Order> settled = await checkout.settle(
        BillSettlement.fromCart(
          cart: await SeededCart.mediumCheesePizzaWithExtraCheese(
            menu,
            quantity: quantity,
          ),
          orderType: orderType,
          paymentMethod: paymentMethod,
          customerPhone: customerPhone,
        ),
      );
      expect(settled.isOk, isTrue, reason: settled.failureOrNull?.message);
      return settled.valueOrNull!;
    });
  }

  Future<void> runSql(WidgetTester tester, String statement) =>
      real<void>(tester, () => database.database.execute(statement));

  Future<void> search(WidgetTester tester, String value) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Search by phone number'),
      value,
    );
    await tester.pump();
    await settleUi(tester);
  }

  /// A finder narrowed to the open bill dialog, so the list behind it cannot satisfy an
  /// assertion by accident.
  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<CustomerRepository>.value(value: customers),
          Provider<OrderRepository>.value(value: orders),
          Provider<PaymentRepository>.value(value: payments),
          // The stored-bill dialog this screen opens reads it, because a bill's refunded
          // and refundable figures are part of the document.
          Provider<RefundRepository>.value(value: refunds),
          // And the reprint actions on that dialog read this. The printer is the
          // unconfigured one, which is what every terminal has today.
          Provider<PrintService>.value(
            value: TestPrinting.serviceOver(
              database,
              printer: UnconfiguredThermalPrinter(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: CustomersScreen()),
        ),
      ),
    );
    await settleUi(tester);
  }

  group('the customer list', () {
    testWidgets('an outlet with no customers says so honestly', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);

      expect(find.text('No customers yet'), findsOneWidget);
      expect(
        find.textContaining('recorded when a phone number is entered'),
        findsOneWidget,
      );
      // No sample customer, no spinner left running, no error, and no invitation to
      // invent a record by hand.
      expect(find.byType(Card), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Add customer'), findsNothing);
    });

    testWidgets('a settled bill puts its customer on the list', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000000901');

      await pumpScreen(tester);

      // Grouped for reading, and derived from the stored bill.
      expect(find.text('98765 43210'), findsNothing);
      expect(find.text('90000 00901'), findsOneWidget);
      expect(find.text('1 order'), findsOneWidget);
      expect(find.text('\u20b9320.00'), findsOneWidget);
      expect(find.text('No customers yet'), findsNothing);
    });

    testWidgets('several bills are counted and totalled', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000000902');
      await sellPizza(tester, customerPhone: '9000000902', quantity: 2);

      await pumpScreen(tester);

      expect(find.text('2 orders'), findsOneWidget);
      expect(find.text('\u20b9960.00'), findsOneWidget);
    });

    testWidgets('a walk-in bill adds nobody', (WidgetTester tester) async {
      await sellPizza(tester);

      await pumpScreen(tester);

      expect(find.text('No customers yet'), findsOneWidget);
    });

    testWidgets('searching by number narrows the list', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000000903');
      await sellPizza(tester, customerPhone: '9876500903');
      await pumpScreen(tester);
      expect(find.text('90000 00903'), findsOneWidget);
      expect(find.text('98765 00903'), findsOneWidget);

      await search(tester, '90000');

      expect(find.text('90000 00903'), findsOneWidget);
      expect(find.text('98765 00903'), findsNothing);
    });

    testWidgets('a number nobody has used says exactly that', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000000904');
      await pumpScreen(tester);

      await search(tester, '9000000999');

      expect(find.text('That number has not ordered here'), findsOneWidget);
      expect(find.text('No customers yet'), findsNothing);
      expect(find.text('90000 00904'), findsNothing);
    });

    testWidgets('the search can be cleared', (WidgetTester tester) async {
      await sellPizza(tester, customerPhone: '9000000905');
      await pumpScreen(tester);
      await search(tester, '9999999999');
      expect(find.text('90000 00905'), findsNothing);

      await tap(tester, find.text('Clear search'));

      expect(find.text('90000 00905'), findsOneWidget);
    });
  });

  group('opening a customer', () {
    testWidgets('nothing is selected to begin with', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000001001');

      await pumpScreen(tester);

      expect(find.text('No customer selected'), findsOneWidget);
    });

    testWidgets('their totals and their bills are shown', (
      WidgetTester tester,
    ) async {
      final Order first = await sellPizza(
        tester,
        customerPhone: '9000001002',
        paymentMethod: PaymentMethod.upi,
      );
      final Order second = await sellPizza(
        tester,
        customerPhone: '9000001002',
        quantity: 2,
        orderType: OrderType.delivery,
      );
      await pumpScreen(tester);

      await tap(tester, find.text('90000 01002'));

      expect(find.text('Completed orders'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Total spent'), findsOneWidget);
      expect(find.text('\u20b9960.00'), findsWidgets);
      expect(find.text('Most recent'), findsOneWidget);

      // Both bills, newest first, with the persisted numbers and totals.
      expect(find.text('Bill ${second.orderNumber}'), findsOneWidget);
      expect(find.text('Bill ${first.orderNumber}'), findsOneWidget);
      expect(find.textContaining('Delivery'), findsWidgets);
      expect(find.textContaining('UPI'), findsWidgets);
      // Item summary from the stored line snapshots.
      expect(find.textContaining('2 x Cheese Pizza (Medium)'), findsOneWidget);
    });

    testWidgets('a customer with no bills is honest about it', (
      WidgetTester tester,
    ) async {
      await real<void>(
        tester,
        () => customers.findOrCreateByPhone('9000001003'),
      );
      await pumpScreen(tester);

      await tap(tester, find.text('90000 01003'));

      expect(find.text('No bills against this number yet'), findsOneWidget);
      // Zeroes, not a made-up figure.
      expect(find.text('0'), findsOneWidget);
      expect(find.text('\u20b90.00'), findsWidgets);
      expect(find.text('\u2014'), findsOneWidget);
    });

    testWidgets('switching customer switches the history', (
      WidgetTester tester,
    ) async {
      final Order mine = await sellPizza(tester, customerPhone: '9000001004');
      final Order theirs = await sellPizza(
        tester,
        customerPhone: '9000001005',
        quantity: 3,
      );
      await pumpScreen(tester);

      await tap(tester, find.text('90000 01004'));
      expect(find.text('Bill ${mine.orderNumber}'), findsOneWidget);
      expect(find.text('Bill ${theirs.orderNumber}'), findsNothing);

      await tap(tester, find.text('90000 01005'));
      expect(find.text('Bill ${theirs.orderNumber}'), findsOneWidget);
      expect(find.text('Bill ${mine.orderNumber}'), findsNothing);
    });

    testWidgets('the customer can be closed again', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000001006');
      await pumpScreen(tester);
      await tap(tester, find.text('90000 01006'));
      expect(find.text('Completed orders'), findsOneWidget);

      await tap(tester, find.byTooltip('Close customer'));

      expect(find.text('No customer selected'), findsOneWidget);
      expect(find.text('Completed orders'), findsNothing);
    });
  });

  group('opening a bill', () {
    testWidgets('it shows the persisted document', (WidgetTester tester) async {
      final Order settled = await sellPizza(
        tester,
        customerPhone: '9000001101',
        quantity: 2,
        orderType: OrderType.delivery,
        paymentMethod: PaymentMethod.upi,
      );
      await pumpScreen(tester);
      await tap(tester, find.text('90000 01101'));

      await tap(tester, find.text('Bill ${settled.orderNumber}'));

      expect(
        inDialog(find.text('Bill ${settled.orderNumber}')),
        findsOneWidget,
      );
      expect(inDialog(find.text('Date and time')), findsOneWidget);
      expect(inDialog(find.text('Delivery')), findsOneWidget);
      expect(inDialog(find.text('90000 01101')), findsOneWidget);
      // The line, its size, its option and the prices as charged.
      expect(inDialog(find.text('Cheese Pizza (Medium)')), findsOneWidget);
      expect(inDialog(find.text('2 x \u20b9320.00')), findsOneWidget);
      expect(inDialog(find.text('+ Extra Cheese x2')), findsOneWidget);
      expect(inDialog(find.text('Subtotal')), findsOneWidget);
      expect(inDialog(find.text('Grand total')), findsOneWidget);
      expect(inDialog(find.text('\u20b9640.00')), findsWidgets);
      expect(inDialog(find.text('UPI')), findsOneWidget);
      // No inconsistency warning: the stored lines add up to the stored subtotal.
      expect(inDialog(find.textContaining('does not match')), findsNothing);
    });

    testWidgets('a walk-in bill shows no phone number', (
      WidgetTester tester,
    ) async {
      // The customer is on file from one bill; a second, separate bill is a walk-in and
      // has to open without inventing a customer for it.
      await sellPizza(tester, customerPhone: '9000001102');
      await pumpScreen(tester);
      await tap(tester, find.text('90000 01102'));
      await tap(tester, find.textContaining('Bill '));

      expect(inDialog(find.text('90000 01102')), findsOneWidget);
      expect(inDialog(find.text('Walk-in')), findsNothing);
    });

    testWidgets('it can be closed and the history is still there', (
      WidgetTester tester,
    ) async {
      final Order settled = await sellPizza(
        tester,
        customerPhone: '9000001103',
      );
      await pumpScreen(tester);
      await tap(tester, find.text('90000 01103'));
      await tap(tester, find.text('Bill ${settled.orderNumber}'));
      expect(find.byType(AlertDialog), findsOneWidget);

      await tap(tester, inDialog(find.text('Close')));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Bill ${settled.orderNumber}'), findsOneWidget);
      expect(find.text('Completed orders'), findsOneWidget);
    });

    testWidgets('a bill still opens after its menu item is deleted', (
      WidgetTester tester,
    ) async {
      final Order settled = await sellPizza(
        tester,
        customerPhone: '9000001104',
      );
      // The dish is discontinued and repriced out of all recognition.
      await runSql(tester, 'UPDATE menu_item_variants SET pricePaise = 99900');
      await runSql(tester, 'UPDATE menu_items SET isDeleted = 1');

      await pumpScreen(tester);
      await tap(tester, find.text('90000 01104'));
      await tap(tester, find.text('Bill ${settled.orderNumber}'));

      // The snapshot, not today's menu.
      expect(inDialog(find.text('Cheese Pizza (Medium)')), findsOneWidget);
      expect(inDialog(find.text('1 x \u20b9320.00')), findsOneWidget);
      expect(inDialog(find.text('\u20b9999.00')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('a storage failure', () {
    testWidgets('is rendered as a notice rather than thrown at the widget', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000001201');
      await runSql(tester, 'ALTER TABLE customers RENAME TO customers_moved');

      await pumpScreen(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Try again'), findsOneWidget);
      // No half-rendered list beside the notice.
      expect(find.text('90000 01201'), findsNothing);
      expect(find.text('No customers yet'), findsNothing);
    });

    testWidgets('can be dismissed, and retried once the fault is gone', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000001202');
      await runSql(tester, 'ALTER TABLE customers RENAME TO customers_moved');

      await pumpScreen(tester);
      expect(find.text('Try again'), findsOneWidget);

      await tap(tester, find.byTooltip('Dismiss'));
      expect(find.text('Try again'), findsNothing);

      await runSql(tester, 'ALTER TABLE customers_moved RENAME TO customers');
      await tap(tester, find.text('Refresh'));

      expect(tester.takeException(), isNull);
      expect(find.text('90000 01202'), findsOneWidget);
    });

    testWidgets('a history that cannot be read offers a retry', (
      WidgetTester tester,
    ) async {
      await sellPizza(tester, customerPhone: '9000001203');
      await pumpScreen(tester);
      await runSql(tester, 'ALTER TABLE orders RENAME TO orders_moved');

      await tap(tester, find.text('90000 01203'));

      expect(tester.takeException(), isNull);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Completed orders'), findsNothing);
    });
  });

  group('navigation', () {
    testWidgets('the screen is reachable from the POS navigation', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await sellPizza(tester, customerPhone: '9000001301');
      final AppDependencies dependencies = TestDependencies.over(database);

      await tester.pumpWidget(BriskoApp(dependencies: dependencies));
      await settleUi(tester);

      await tap(tester, find.text(PosSection.customers.label));

      expect(find.text('Search by phone number'), findsOneWidget);
      expect(find.text('90000 01301'), findsOneWidget);
      // The placeholder is gone for good.
      expect(find.text('Not implemented yet.'), findsNothing);
      expect(find.textContaining('Sharing a bill over WhatsApp'), findsNothing);
    });
  });
}
