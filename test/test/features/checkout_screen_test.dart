import 'package:brisko_billing/app/routes/app_routes.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/gst_rate.dart';
import 'package:brisko_billing/features/billing/domain/repositories/checkout_repository.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/screens/billing_screen.dart';
import 'package:brisko_billing/features/billing/presentation/screens/checkout_screen.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/repositories/customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/domain/active_pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/fake_escpos_printer.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// The settlement flow driven by tapping, over the real database and seeded menu.
///
/// Proves the cashier can get from a cart to a persisted bill without leaving the
/// application, that they can back out at every point before the charge, and that a
/// storage failure arrives as a rendered notice rather than an exception.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkoutRepository;
  late BillingController billing;
  late FakeEscPosPrinter printer;
  late PrintService printing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkoutRepository = SqliteCheckoutRepository(database: database);
    printer = FakeEscPosPrinter();
    printing = TestPrinting.serviceOver(database, printer: printer);
    billing = BillingController(menuRepository: menu);
  });

  tearDown(() async {
    billing.dispose();
    await database.close();
  });

  /// Lets the real database work finish, then renders the result.
  ///
  /// The widget binding drives a fake clock and sqflite answers from a background
  /// isolate, so a query's completion is not delivered until the real event loop gets a
  /// turn. Without this the screen would sit on a loading state forever.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await settle(tester);
  }

  /// Pumps the billing screen with the checkout route registered, as the app wires it.
  ///
  /// [gstRate] is the outlet's configured rate, supplied through `ActivePosSettings` exactly
  /// as `BriskoApp` supplies it. Left out, the terminal has configured none, which is what a
  /// fresh install is and what every test below this one assumes.
  Future<void> pumpBilling(
    WidgetTester tester, {
    GstRate gstRate = GstRate.zero,
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BillingController>.value(value: billing),
          Provider<ActivePosSettings>.value(
            value: ActivePosSettings(settings: PosSettings(gstRate: gstRate)),
          ),
          Provider<CheckoutRepository>.value(value: checkoutRepository),
          Provider<CustomerRepository>.value(
            value: SqliteCustomerRepository(database: database),
          ),
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
    await settle(tester);
  }

  /// Rings up a Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  Future<void> ringUpPizza(WidgetTester tester) async {
    await tap(tester, find.text('Cheese Pizza'));
    await tap(tester, find.textContaining('Medium'));
    await tap(tester, find.textContaining('Extra Cheese'));
    await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));
  }

  /// Anything inside the checkout route, so the billing screen underneath it cannot
  /// satisfy an assertion by accident.
  Finder inCheckout(Finder matching) =>
      find.descendant(of: find.byType(CheckoutScreen), matching: matching);

  Future<void> openCheckout(WidgetTester tester) =>
      tap(tester, find.widgetWithText(FilledButton, 'Checkout \u20b9320.00'));

  /// Name every order requires before payment. Phone is optional.
  Future<void> fillCustomer(WidgetTester tester) async {
    await tester.enterText(
      inCheckout(find.widgetWithText(TextField, 'Customer name')),
      'Test Customer',
    );
    await tester.enterText(
      inCheckout(find.widgetWithText(TextField, 'Phone number')),
      '9000000001',
    );
    await settle(tester);
  }

  group('opening checkout from the cart', () {
    testWidgets('the button is disabled until there is a bill', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);

      final Finder checkout = find.widgetWithText(
        FilledButton,
        'Checkout \u20b90.00',
      );
      expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
    });

    testWidgets('the button carries the amount and opens the flow', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);

      expect(
        find.widgetWithText(FilledButton, 'Checkout \u20b9320.00'),
        findsOneWidget,
      );

      await openCheckout(tester);

      expect(find.byType(CheckoutScreen), findsOneWidget);
      expect(find.text('Review bill'), findsOneWidget);
      // The bill summary restates what is being charged.
      expect(inCheckout(find.text('Cheese Pizza (Medium)')), findsOneWidget);
      expect(inCheckout(find.text('Total')), findsOneWidget);
      expect(inCheckout(find.text('Order type')), findsOneWidget);
    });
  });

  group('taking payment', () {
    testWidgets('cash: exact tender, confirm, settled', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);

      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      expect(find.text('Payment'), findsWidgets);
      expect(inCheckout(find.text('Payment method')), findsOneWidget);

      await tap(tester, inCheckout(find.text('Cash')));
      expect(inCheckout(find.text('Cash received')), findsOneWidget);
      expect(inCheckout(find.text('Still needed')), findsOneWidget);

      // Not enough on the counter yet.
      final Finder review = find.widgetWithText(FilledButton, 'Review payment');
      expect(tester.widget<FilledButton>(review).onPressed, isNull);

      await tap(tester, find.widgetWithText(OutlinedButton, 'Exact'));
      expect(inCheckout(find.text('Change')), findsOneWidget);
      expect(tester.widget<FilledButton>(review).onPressed, isNotNull);

      await tap(tester, review);
      expect(find.text('Confirm payment'), findsOneWidget);
      expect(inCheckout(find.text('Test Customer')), findsOneWidget);

      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Bill settled'), findsWidgets);
      expect(
        find.textContaining(RegExp(r'^Order \d{8}-0001$')),
        findsOneWidget,
      );
      expect(inCheckout(find.text('Collected')), findsOneWidget);
      expect(inCheckout(find.text('Completed')), findsOneWidget);
    });

    testWidgets('cash: the keypad and the change owed', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('Cash')));

      // 5, 0, 0, then two zeroes at once: ₹500.00
      await tap(tester, find.widgetWithText(OutlinedButton, '5'));
      await tap(tester, find.widgetWithText(OutlinedButton, '0'));
      await tap(tester, find.widgetWithText(OutlinedButton, '0'));
      await tap(tester, find.widgetWithText(OutlinedButton, '00'));

      expect(inCheckout(find.text('\u20b9500.00')), findsOneWidget);
      expect(inCheckout(find.text('\u20b9180.00')), findsOneWidget);

      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));
      expect(inCheckout(find.text('Cash tendered')), findsOneWidget);
      expect(inCheckout(find.text('Change to give')), findsOneWidget);

      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );

      expect(find.text('Give change'), findsOneWidget);
      expect(inCheckout(find.text('\u20b9180.00')), findsOneWidget);
    });

    testWidgets('a short tender cannot be confirmed', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('Cash')));

      // ₹200 against a ₹320 bill.
      await tap(tester, find.widgetWithText(OutlinedButton, '+\u20b9200.00'));

      expect(inCheckout(find.text('Still needed')), findsOneWidget);
      expect(inCheckout(find.text('\u20b9120.00')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review payment'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('upi: no tender to count, a reference to record', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));

      await tap(tester, inCheckout(find.text('UPI')));

      expect(inCheckout(find.text('Cash received')), findsNothing);
      expect(inCheckout(find.text('Reference')), findsOneWidget);
      expect(
        inCheckout(find.textContaining('UPI of \u20b9320.00 will be recorded')),
        findsOneWidget,
      );

      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Reference')),
        'UPI-4242',
      );
      await settle(tester);

      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));
      expect(inCheckout(find.text('UPI-4242')), findsOneWidget);

      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );
      expect(find.text('Bill settled'), findsWidgets);
    });
  });

  group('backing out', () {
    testWidgets('every step before the charge can be walked back', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('Cash')));
      await tap(tester, find.widgetWithText(OutlinedButton, 'Exact'));
      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));
      expect(find.text('Confirm payment'), findsOneWidget);

      await tap(tester, find.byType(BackButton));
      expect(find.text('Payment'), findsWidgets);
      // The counted cash is still there.
      expect(inCheckout(find.text('Change')), findsOneWidget);

      await tap(tester, find.byType(BackButton));
      expect(find.text('Review bill'), findsOneWidget);

      // One more leaves the flow entirely.
      await tap(tester, find.byType(BackButton));

      expect(find.byType(CheckoutScreen), findsNothing);
      // And the bill is exactly where it was.
      expect(
        find.widgetWithText(FilledButton, 'Checkout \u20b9320.00'),
        findsOneWidget,
      );
      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);
    });

    testWidgets('a settled bill has no way back, only a new bill', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('Cash')));
      await tap(tester, find.widgetWithText(OutlinedButton, 'Exact'));
      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );

      expect(find.byType(BackButton), findsNothing);

      await tap(tester, find.widgetWithText(FilledButton, 'Start a new bill'));

      // Back on billing, with an empty cart.
      expect(find.byType(CheckoutScreen), findsNothing);
      expect(find.text('No items yet'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Checkout \u20b90.00'),
        findsOneWidget,
      );
    });
  });

  group('a failed charge', () {
    testWidgets('is reported on screen and keeps the bill', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);
      await fillCustomer(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Take payment'));
      await tap(tester, inCheckout(find.text('UPI')));
      await tap(tester, find.widgetWithText(FilledButton, 'Review payment'));

      // The database goes away between confirming and charging.
      await tester.runAsync(database.close);
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Bill settled'), findsNothing);
      expect(find.text('The bill was not settled'), findsOneWidget);
      expect(find.textContaining('Nothing was recorded'), findsOneWidget);
      // Still on confirm, and the charge can be tried again.
      expect(find.text('Confirm payment'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Charge \u20b9320.00'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the discount control', () {
    testWidgets('it is closed on a bill nobody is discounting', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);

      expect(inCheckout(find.text('Discount')), findsOneWidget);
      expect(
        inCheckout(find.text('No discount on this bill.')),
        findsOneWidget,
      );
      // No field until it is asked for. Most bills carry no discount, so the review step
      // does not present one that almost always stays empty.
      expect(inCheckout(find.text('Discount percentage')), findsNothing);
      expect(
        inCheckout(find.widgetWithText(FilledButton, 'Take payment')),
        findsOneWidget,
      );
    });

    testWidgets('a percentage moves the summary and the payable amount', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester, gstRate: const GstRate.ofBasisPoints(1800));
      await ringUpPizza(tester);
      await openCheckout(tester);

      // 320 at 18% is 57.60, total 377.60, and the split is 28.80 each way.
      expect(inCheckout(find.text('CGST 9%')), findsOneWidget);
      expect(inCheckout(find.text('\u20b928.80')), findsNWidgets(2));
      expect(inCheckout(find.text('\u20b9377.60')), findsWidgets);

      await tap(tester, inCheckout(find.byType(Switch)));
      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Discount percentage')),
        '10',
      );
      await tester.pump();
      await settle(tester);

      // 32.00 off, 288.00 taxable, 51.84 tax, 339.84 total.
      expect(inCheckout(find.text('Discount (10%)')), findsOneWidget);
      expect(inCheckout(find.text('-\u20b932.00')), findsOneWidget);
      expect(inCheckout(find.text('Taxable amount')), findsOneWidget);
      expect(inCheckout(find.text('\u20b9288.00')), findsWidgets);
      expect(inCheckout(find.text('\u20b925.92')), findsNWidgets(2));
      expect(inCheckout(find.text('\u20b9339.84')), findsWidgets);
      // And the amount on the action bar follows, so the button cannot promise one figure
      // while the summary shows another.
      expect(inCheckout(find.text('\u20b9377.60')), findsNothing);
    });

    testWidgets('a fixed amount is taken off in rupees', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);

      await tap(tester, inCheckout(find.byType(Switch)));
      await tap(tester, inCheckout(find.text('Amount \u20b9')));
      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Discount amount')),
        '20',
      );
      await tester.pump();
      await settle(tester);

      expect(inCheckout(find.text('Discount (\u20b920.00)')), findsOneWidget);
      expect(inCheckout(find.text('-\u20b920.00')), findsOneWidget);
      expect(inCheckout(find.text('\u20b9300.00')), findsWidgets);
      // No tax configured, so no taxable-amount row and no CGST or SGST.
      expect(inCheckout(find.text('Taxable amount')), findsNothing);
      expect(inCheckout(find.textContaining('CGST')), findsNothing);
    });

    testWidgets('a refused discount is reported and blocks the step', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);

      await tap(tester, inCheckout(find.byType(Switch)));
      await tap(tester, inCheckout(find.text('Amount \u20b9')));
      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Discount amount')),
        '500',
      );
      await tester.pump();
      await settle(tester);

      // Says what the ceiling is, rather than only that the answer is no.
      expect(
        inCheckout(find.textContaining('cannot be more than the 320.00')),
        findsOneWidget,
      );
      // The bill is unchanged, and the step will not advance on a refused figure.
      expect(inCheckout(find.text('\u20b9320.00')), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(
              inCheckout(find.widgetWithText(FilledButton, 'Take payment')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('turning the control off puts the bill back', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester);
      await ringUpPizza(tester);
      await openCheckout(tester);

      await tap(tester, inCheckout(find.byType(Switch)));
      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Discount percentage')),
        '25',
      );
      await tester.pump();
      await settle(tester);
      expect(inCheckout(find.text('-\u20b980.00')), findsOneWidget);

      await tap(tester, inCheckout(find.byType(Switch)));

      // Removed, not hidden. A reduction with nothing on screen explaining it is the one
      // state this must never be in.
      expect(inCheckout(find.textContaining('-\u20b9')), findsNothing);
      expect(
        inCheckout(find.text('No discount on this bill.')),
        findsOneWidget,
      );
      expect(inCheckout(find.text('\u20b9320.00')), findsWidgets);
    });

    testWidgets('a discounted taxed bill charges and settles the shown total', (
      WidgetTester tester,
    ) async {
      await pumpBilling(tester, gstRate: const GstRate.ofBasisPoints(500));
      await ringUpPizza(tester);
      await openCheckout(tester);

      await tap(tester, inCheckout(find.byType(Switch)));
      await tester.enterText(
        inCheckout(find.widgetWithText(TextField, 'Discount percentage')),
        '10',
      );
      await tester.pump();
      await settle(tester);

      // 320 less 32 is 288, at 5% that is 14.40, total 302.40.
      await fillCustomer(tester);
      await tap(
        tester,
        inCheckout(find.widgetWithText(FilledButton, 'Take payment')),
      );
      await tap(tester, inCheckout(find.text('Cash')));
      await tap(tester, inCheckout(find.textContaining('Exact')));
      await tap(
        tester,
        inCheckout(find.widgetWithText(FilledButton, 'Review payment')),
      );

      final Finder charge = inCheckout(
        find.widgetWithText(FilledButton, 'Charge \u20b9302.40'),
      );
      expect(charge, findsOneWidget);

      await tap(tester, charge);

      expect(tester.takeException(), isNull);
      // The step label and the success heading both say it.
      expect(find.text('Bill settled'), findsWidgets);

      // And the committed row is the amount that was on the button.
      //
      // Read through `runAsync`, because a widget test body runs inside a fake-async zone
      // where real I/O never completes and sqflite answers from outside it.
      final List<Map<String, Object?>> rows = (await tester.runAsync(
        () => database.database.query('orders'),
      ))!;
      expect(rows, hasLength(1));
      expect(rows.single['subtotalPaise'], 32000);
      expect(rows.single['discountAmountPaise'], 3200);
      expect(rows.single['taxAmountPaise'], 1440);
      expect(rows.single['totalAmountPaise'], 30240);
      expect(rows.single['taxRateBasisPoints'], 500);
      expect(rows.single['discountType'], 'percentage');
      expect(rows.single['discountValue'], 1000);
    });
  });
}
