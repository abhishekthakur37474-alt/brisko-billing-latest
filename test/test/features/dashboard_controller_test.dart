import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/report_period.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// The dashboard's state, over the real schema.
///
/// The dashboard reuses the reports aggregation and the inventory low-stock query rather
/// than counting anything itself, so these tests drive the real repositories: what is
/// asserted is that the controller surfaces the same figures the reports would, for the
/// period selected, and that discount, GST, refund and net keep their Step 14 meanings.
void main() {
  setUpAll(TestDatabase.register);

  /// A fixed instant standing in for now, so "today" is the same in every run.
  final DateTime now = DateTime(2026, 9, 13, 15, 30);

  DateTime dayAt(int daysAgo, {int hour = 12, int minute = 0}) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  late SqliteDatabase database;
  late SqliteSalesReportRepository reports;
  late InventoryRepository inventory;
  late SqliteRefundRepository refunds;
  late SeededSales seed;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    reports = SqliteSalesReportRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    refunds = SqliteRefundRepository(database: database);
    seed = SeededSales(database);
  });

  tearDown(() async {
    await database.close();
  });

  DashboardController controllerFor() {
    final DashboardController controller = DashboardController(
      reportRepository: reports,
      inventoryRepository: inventory,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('an empty outlet', () {
    test('reports no sales rather than a screen of zeroes', () async {
      final DashboardController controller = controllerFor();

      await controller.load();

      expect(controller.hasLoaded, isTrue);
      expect(controller.hasError, isFalse);
      expect(controller.isEmpty, isTrue);
      expect(controller.summary.billCount, 0);
      expect(controller.summary.grossSales, Money.zero);
      expect(controller.recentBills, isEmpty);
      expect(controller.topItems, isEmpty);
      expect(controller.hasLowStock, isFalse);
    });
  });

  group("today's figures", () {
    setUp(() async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        paymentMethod: PaymentMethod.cash,
        subtotal: '400.00',
        discount: '40.00',
        tax: '18.00',
        total: '378.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Pizza',
            variantName: 'Large',
            quantity: 2,
            unitPrice: '200.00',
            total: '400.00',
          ),
        ],
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        paymentMethod: PaymentMethod.upi,
        subtotal: '100.00',
        discount: '0.00',
        tax: '5.00',
        total: '105.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Fries',
            variantName: null,
            quantity: 1,
            unitPrice: '100.00',
            total: '100.00',
          ),
        ],
      );
    });

    test('gross, discounts, GST and net keep their Step 14 meanings', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.isEmpty, isFalse);
      // 378 + 105.
      expect(controller.summary.grossSales, Money.parse('483.00'));
      expect(controller.summary.discountTotal, Money.parse('40.00'));
      // GST is a single figure, never CGST + SGST added on top of it.
      expect(controller.summary.taxTotal, Money.parse('23.00'));
      expect(
        controller.summary.cgstTotal + controller.summary.sgstTotal,
        controller.summary.taxTotal,
      );
      // No refunds yet, so net equals gross.
      expect(controller.summary.refundTotal, Money.zero);
      expect(controller.summary.netSales, Money.parse('483.00'));
    });

    test('order count and average order value', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.summary.billCount, 2);
      // 48300 paise over two bills.
      expect(controller.summary.averageBillValue, const Money.fromPaise(24150));
    });

    test('payment mix splits the takings across the methods', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(
        controller.paymentMix.amountFor(PaymentMethod.cash),
        Money.parse('378.00'),
      );
      expect(
        controller.paymentMix.amountFor(PaymentMethod.upi),
        Money.parse('105.00'),
      );
      expect(controller.paymentMix.amountFor(PaymentMethod.card), Money.zero);
      expect(controller.paymentMix.amountFor(PaymentMethod.other), Money.zero);
      expect(controller.paymentMix.total, Money.parse('483.00'));
    });

    test('top items are the best sellers, most valuable first', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.topItems, hasLength(2));
      expect(controller.topItems.first.displayName, 'Pizza (Large)');
      expect(controller.topItems.first.salesAmount, Money.parse('400.00'));
    });

    test('recent orders are the settled bills, newest first', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(
        controller.recentBills.map((dynamic b) => b.orderNumber).toList(),
        <String>['20260913-0002', '20260913-0001'],
      );
    });
  });

  group('refunds', () {
    test('a refund reduces net sales without touching gross', () async {
      final String orderId = await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        paymentMethod: PaymentMethod.cash,
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );
      final RefundableBill refundable = (await refunds.loadRefundable(orderId))
          .valueOrNull!;
      await refunds.refund(RefundRequest.forBill(refundable));

      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.summary.grossSales, Money.parse('200.00'));
      expect(controller.summary.refundTotal, Money.parse('200.00'));
      expect(controller.summary.netSales, Money.zero);
      // Still one settled bill: a refund does not remove the sale.
      expect(controller.summary.billCount, 1);
    });
  });

  group('date periods', () {
    setUp(() async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 10),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260912-0001',
        at: dayAt(1, hour: 19),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );
      await seed.bill(
        orderNumber: '20260909-0001',
        at: dayAt(4, hour: 13),
        subtotal: '400.00',
        tax: '0.00',
        total: '400.00',
      );
    });

    test('today shows only today', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.period, ReportPeriod.today);
      expect(controller.summary.grossSales, Money.parse('100.00'));
    });

    test('yesterday reads the previous day', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      await controller.selectPeriod(ReportPeriod.yesterday);

      expect(controller.period, ReportPeriod.yesterday);
      expect(controller.summary.grossSales, Money.parse('200.00'));
    });

    test('last 7 days covers this day and the six before it', () async {
      final DashboardController controller = controllerFor();
      await controller.load();

      await controller.selectPeriod(ReportPeriod.last7Days);

      // 100 + 200 + 400.
      expect(controller.summary.grossSales, Money.parse('700.00'));
    });
  });

  group('low stock', () {
    test('items at or below their threshold are surfaced', () async {
      // A monitored item with nothing on the shelf.
      await inventory.saveItem(
        Fixtures.inventoryItem(
          name: 'Mozzarella',
          currentQuantity: '0',
          minimumQuantity: '2',
        ),
      );
      // A monitored item that is well stocked is not low.
      await inventory.saveItem(
        Fixtures.inventoryItem(
          name: 'Flour',
          currentQuantity: '0',
          minimumQuantity: '0',
        ),
      );

      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.hasLowStock, isTrue);
      expect(controller.lowStock.map((dynamic i) => i.name).toList(), <String>[
        'Mozzarella',
      ]);
    });
  });

  group('limits', () {
    test('recent orders are capped and top items are capped', () async {
      for (int index = 1; index <= 12; index++) {
        await seed.bill(
          orderNumber: '20260913-${index.toString().padLeft(4, '0')}',
          at: dayAt(0, hour: 9, minute: index),
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
          lines: <BillLineSpec>[
            BillLineSpec(
              itemName: 'Item $index',
              variantName: null,
              total: '100.00',
            ),
          ],
        );
      }

      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.summary.billCount, 12);
      expect(
        controller.recentBills.length,
        DashboardController.recentBillsLimit,
      );
      expect(controller.topItems.length, DashboardController.topItemsLimit);
    });
  });

  group('a settled-then-cancelled world', () {
    test('a cancelled bill is not counted on the dashboard', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        status: OrderStatus.completed,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        status: OrderStatus.cancelled,
        subtotal: '999.00',
        tax: '0.00',
        total: '999.00',
      );

      final DashboardController controller = controllerFor();
      await controller.load();

      expect(controller.summary.billCount, 1);
      expect(controller.summary.grossSales, Money.parse('100.00'));
      expect(controller.recentBills, hasLength(1));
    });
  });
}
