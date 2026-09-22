import 'package:brisko_billing/app/routes/app_routes.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/repositories/checkout_repository.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/billing/presentation/screens/billing_screen.dart';
import 'package:brisko_billing/features/billing/presentation/screens/checkout_screen.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/repositories/customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_run.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// The checkout, taken all the way to paper.
///
/// This is the requirement that matters most in the whole printing layer: a printer that
/// fails must not cost the outlet a sale, and the cashier must never be left wondering
/// whether to charge the customer again. Both the controller and the screen are exercised
/// here, because the guarantee is only useful if it is what the cashier actually reads.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkoutRepository;
  late SqliteCustomerRepository customers;
  late FakeEscPosPrinter printer;
  late PrintService printing;
  late BillingController billing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkoutRepository = SqliteCheckoutRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    printer = FakeEscPosPrinter();
    printing = TestPrinting.serviceOver(database, printer: printer);
    billing = await SeededCart.controller(menu);
  });

  tearDown(() async {
    billing.dispose();
    await printer.dispose();
    if (database.isOpen) {
      await database.close();
    }
  });

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<Map<String, int>> saleRows() async => <String, int>{
    'orders': await rowCount('orders'),
    'order_items': await rowCount('order_items'),
    'payments': await rowCount('payments'),
    'kot_records': await rowCount('kot_records'),
    'kot_items': await rowCount('kot_items'),
  };

  // ------------------------------------------------------- controller level ---

  group('the controller', () {
    /// A checkout walked to the point where the money can be taken.
    Future<CheckoutController> readyToCharge() async {
      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
        options: <String>['Extra Cheese'],
      );

      final CheckoutController controller = CheckoutController(
        cart: billing.cart,
        checkoutRepository: checkoutRepository,
        customerRepository: customers,
        inventoryDeductionRepository: SqliteInventoryDeductionRepository(
          database: database,
        ),
        printService: printing,
        onSettled: billing.clearCart,
      );
      addTearDown(controller.dispose);

      controller.setCustomerName('Test Customer');
      controller.setCustomerPhone('9000000001');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.tenderExact();
      controller.goToConfirm();
      return controller;
    }

    test('a settled bill prints both documents', () async {
      final CheckoutController controller = await readyToCharge();

      await controller.submit();

      expect(controller.isSettled, isTrue);
      expect(controller.isPrinted, isTrue);
      expect(controller.hasPrintFailure, isFalse);
      expect(controller.printMessage, isNull);
      expect(printer.documents, hasLength(2));
      expect(
        controller.printRun!.jobs.map((PrintJob job) => job.kind),
        <PrintJobKind>[PrintJobKind.kitchenKot, PrintJobKind.customerReceipt],
      );
    });

    test('turning the kitchen slip off prints only the receipt', () async {
      final CheckoutController controller = await readyToCharge();
      controller.setPrintKitchenSlip(isEnabled: false);

      await controller.submit();

      expect(controller.isSettled, isTrue);
      expect(controller.isPrinted, isTrue);
      expect(printer.documents, hasLength(1));
      expect(
        controller.printRun!.jobs.map((PrintJob job) => job.kind),
        <PrintJobKind>[PrintJobKind.customerReceipt],
      );
      expect(await rowCount('kot_records'), 1);
    });

    test('a printer failure leaves the sale settled and says so', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;

      await controller.submit();

      // The sale. Completely unaffected.
      expect(controller.isSettled, isTrue);
      expect(controller.settledOrder, isNotNull);
      expect(controller.orderNumber, endsWith('-0001'));
      // Not reported through the settlement error, which would read as a failed
      // payment and is what blocks the flow.
      expect(controller.hasError, isFalse);
      expect(controller.errorMessage, isNull);
      expect(controller.step, CheckoutStep.success);

      // The paper.
      expect(controller.hasPrintFailure, isTrue);
      expect(controller.isPrinted, isFalse);
      expect(
        controller.printMessage,
        startsWith(SalePrintRun.paidButNotPrinted),
      );

      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);
    });

    test('the cart is cleared by the sale, not by the printer', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;

      await controller.submit();

      // Cleared on the commit, so the next customer can be served even though the
      // last receipt did not print.
      expect(billing.cart.isEmpty, isTrue);
    });

    test('a retry prints without creating a second bill', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;
      await controller.submit();
      final Map<String, int> afterSale = await saleRows();

      printer.repair();
      await controller.retryPrinting();

      expect(controller.hasPrintFailure, isFalse);
      expect(controller.isPrinted, isTrue);
      expect(printer.documents, hasLength(2));
      // The guarantee: one order, one payment, one slip, however many retries.
      expect(await saleRows(), afterSale);
    });

    test('retrying repeatedly cannot duplicate the sale', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;
      await controller.submit();
      final Map<String, int> afterSale = await saleRows();

      for (int attempt = 0; attempt < 5; attempt++) {
        await controller.retryPrinting();
        expect(controller.hasPrintFailure, isTrue);
      }

      printer.repair();
      await controller.retryPrinting();

      expect(controller.isPrinted, isTrue);
      expect(await saleRows(), afterSale);
      expect(await rowCount('orders'), 1);
    });

    test('the retry re-sends the same documents, not a new sale', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;
      await controller.submit();
      final String orderNumber = controller.orderNumber!;

      printer.repair();
      await controller.retryPrinting();

      final EscPosTranscript receipt = EscPosTranscript.of(
        printer.documents.last,
      );
      expect(receipt.hasLineContaining('Bill $orderNumber'), isTrue);
      // Not marked as a reprint: the customer never received the first copy.
      expect(receipt.text, isNot(contains('REPRINT')));
    });

    test('there is nothing to retry when everything printed', () async {
      final CheckoutController controller = await readyToCharge();
      await controller.submit();

      await controller.retryPrinting();

      expect(printer.documents, hasLength(2));
    });

    test('the notice can be dismissed without touching the sale', () async {
      final CheckoutController controller = await readyToCharge();
      printer.failOnWrite = true;
      await controller.submit();
      expect(controller.hasPrintFailure, isTrue);

      controller.dismissPrintFailure();

      expect(controller.hasPrintFailure, isFalse);
      expect(controller.printMessage, isNull);
      expect(controller.isSettled, isTrue);
      expect(await rowCount('orders'), 1);
    });

    test('a bill that fails to settle is never printed', () async {
      final CheckoutController controller = await readyToCharge();
      await database.close();

      await controller.submit();

      expect(controller.hasError, isTrue);
      expect(controller.isSettled, isFalse);
      // Printing is strictly after persistence, so an unsettled bill produces no
      // paper at all.
      expect(controller.printRun, isNull);
      expect(printer.documents, isEmpty);
    });
  });

  // ----------------------------------------------------------- screen level ---

  group('the success screen', () {
    /// Runs [action] against the real database, outside the fake-async zone.
    ///
    /// A widget test body runs on a controlled clock where real I/O never completes, so
    /// a query awaited directly here would hang rather than fail.
    Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
      final T? value = await tester.runAsync<T>(action);
      return value as T;
    }

    /// Lets the real database and printer work finish, then renders the result.
    ///
    /// Repeated because settlement and printing are two sequential rounds of database
    /// work, and each needs the real event loop to get a turn before the widgets can
    /// show its outcome.
    Future<void> settleUi(WidgetTester tester) async {
      for (int round = 0; round < 3; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
      }
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await settleUi(tester);
    }

    Future<void> pumpBilling(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<BillingController>.value(value: billing),
            Provider<CheckoutRepository>.value(value: checkoutRepository),
            Provider<CustomerRepository>.value(value: customers),
            Provider<InventoryDeductionRepository>.value(
              value: SqliteInventoryDeductionRepository(database: database),
            ),
            Provider<PrintService>.value(value: printing),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: BillingScreen()),
            routes: <String, WidgetBuilder>{
              AppRoutes.checkout: (BuildContext context) =>
                  const CheckoutScreen(),
            },
          ),
        ),
      );
      await settleUi(tester);
    }

    /// Anything inside the checkout route, so the billing screen underneath cannot
    /// satisfy a tap by accident.
    Finder inCheckout(Finder matching) =>
        find.descendant(of: find.byType(CheckoutScreen), matching: matching);

    /// Rings up a Medium Cheese Pizza with Extra Cheese and takes the cash: the same
    /// taps a cashier makes, ending with the charge.
    Future<void> sellPizza(WidgetTester tester) async {
      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.textContaining('Medium'));
      await tap(tester, find.textContaining('Extra Cheese'));
      await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Checkout \u20b9320.00'),
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('Cash')));
      await tap(tester, find.widgetWithText(OutlinedButton, 'Exact'));
      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );
    }

    testWidgets('a printed sale says so quietly', (WidgetTester tester) async {
      await pumpBilling(tester);
      await sellPizza(tester);

      expect(find.text('Bill settled'), findsWidgets);
      expect(find.text('Bill and kitchen slip printed'), findsOneWidget);
      expect(find.text(SalePrintRun.paidButNotPrinted), findsNothing);
      expect(printer.documents, hasLength(2));
    });

    testWidgets('a printer failure tells the cashier the money is safe', (
      WidgetTester tester,
    ) async {
      printer.failOnWrite = true;
      await pumpBilling(tester);
      await sellPizza(tester);

      // The bill is settled and says so, and the printing notice is separate from it.
      expect(find.text('Bill settled'), findsWidgets);
      expect(find.text(SalePrintRun.paidButNotPrinted), findsOneWidget);
      expect(find.text('Try printing again'), findsOneWidget);
      expect(find.text('Continue without printing'), findsOneWidget);
      expect(find.text('Start a new bill'), findsOneWidget);
      expect(tester.takeException(), isNull);

      expect(await real(tester, () => rowCount('orders')), 1);
      expect(await real(tester, () => rowCount('payments')), 1);
      expect(await real(tester, () => rowCount('kot_records')), 1);
    });

    testWidgets('the retry button prints and does not re-charge', (
      WidgetTester tester,
    ) async {
      printer.failOnWrite = true;
      await pumpBilling(tester);
      await sellPizza(tester);
      final Map<String, int> afterSale = await real(tester, saleRows);

      printer.repair();
      await tap(tester, find.text('Try printing again'));

      expect(find.text(SalePrintRun.paidButNotPrinted), findsNothing);
      expect(find.text('Bill and kitchen slip printed'), findsOneWidget);
      expect(printer.documents, hasLength(2));
      expect(await real(tester, saleRows), afterSale);
    });

    testWidgets('the notice can be dismissed and the bill stays settled', (
      WidgetTester tester,
    ) async {
      printer.failOnWrite = true;
      await pumpBilling(tester);
      await sellPizza(tester);

      await tap(tester, find.text('Continue without printing'));

      expect(find.text(SalePrintRun.paidButNotPrinted), findsNothing);
      expect(find.text('Bill settled'), findsWidgets);
      expect(find.text('Start a new bill'), findsOneWidget);
      expect(await real(tester, () => rowCount('orders')), 1);
    });
  });
}
