import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/kot/presentation/screens/kitchen_screen.dart';
import 'package:brisko_billing/features/orders/presentation/widgets/bill_detail_view.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/reports/presentation/screens/order_history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

/// The dashboard and the order history, driven through the real application.
///
/// Built as `BriskoApp` over an in-memory database so the wiring — the dashboard's reads,
/// the route to the order history, and the untouched Orders → Kitchen navigation — is what
/// is exercised, not a screen in isolation.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;

  /// A settled bill a few hours into today, so it sits inside today wherever the suite runs.
  DateTime todayAt(int hour) {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour);
  }

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
  });

  tearDown(() async {
    await database.close();
  });

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

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      BriskoApp(dependencies: TestDependencies.over(database)),
    );
    await settleUi(tester);
  }

  group('the dashboard', () {
    testWidgets('with no sales says so rather than showing zeroes', (
      WidgetTester tester,
    ) async {
      await openApp(tester);

      expect(find.textContaining('No sales'), findsOneWidget);
      // No invented figure.
      expect(find.textContaining('₹'), findsNothing);
      // The period filters are offered.
      expect(find.widgetWithText(ChoiceChip, 'Today'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Last 7 days'), findsOneWidget);
    });

    testWidgets("shows today's takings, mix and top items", (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await seed.bill(
          orderNumber: '20260913-0001',
          at: todayAt(10),
          paymentMethod: PaymentMethod.cash,
          subtotal: '400.00',
          tax: '0.00',
          total: '400.00',
          lines: const <BillLineSpec>[
            BillLineSpec(
              itemName: 'Dash Pizza',
              variantName: 'Large',
              quantity: 2,
              unitPrice: '200.00',
              total: '400.00',
            ),
          ],
        );
        await seed.bill(
          orderNumber: '20260913-0002',
          at: todayAt(11),
          paymentMethod: PaymentMethod.upi,
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );
      });

      await openApp(tester);

      expect(find.text('Gross sales'), findsOneWidget);
      expect(find.text('₹500.00'), findsWidgets);
      expect(find.text('Payment mix'), findsOneWidget);
      expect(find.text('Top selling items'), findsOneWidget);
      expect(find.text('Dash Pizza (Large)'), findsOneWidget);
      expect(find.text('Recent orders'), findsOneWidget);
      expect(find.text('Bill 20260913-0002'), findsOneWidget);
    });

    testWidgets('a recent order opens the stored bill', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await seed.bill(
          orderNumber: '20260913-0001',
          at: todayAt(10),
          paymentMethod: PaymentMethod.cash,
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );
      });

      await openApp(tester);
      await tap(tester, find.text('Bill 20260913-0001'));

      expect(find.byType(BillDetailView), findsOneWidget);
    });
  });

  group('the order history', () {
    testWidgets('opens from the dashboard and finds a bill', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await seed.bill(
          orderNumber: '20260913-0055',
          at: todayAt(10),
          paymentMethod: PaymentMethod.cash,
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );
      });

      await openApp(tester);
      await tap(tester, find.text('Order history'));

      expect(find.byType(OrderHistoryScreen), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Bill number'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Customer phone'), findsOneWidget);
      // The default week already lists today's bill.
      expect(find.text('Bill 20260913-0055'), findsOneWidget);
    });
  });

  group('kitchen separation', () {
    testWidgets('the Orders section is still the kitchen board', (
      WidgetTester tester,
    ) async {
      await openApp(tester);

      await tap(tester, find.text(PosSection.orders.label));

      // Orders is the live kitchen, not the order history.
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(find.byType(OrderHistoryScreen), findsNothing);
    });
  });
}
