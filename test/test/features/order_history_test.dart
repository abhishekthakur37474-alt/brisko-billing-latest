import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/bill_search_query.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/report_period.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/presentation/controllers/order_history_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// The order-history search, over the real schema.
///
/// The search is one indexed query rather than a scan in Dart, so it is driven against the
/// real database exactly as the reports are: what is asserted is that a cashier finds the
/// bill they are looking for, and never a cancelled or unsettled record.
void main() {
  setUpAll(TestDatabase.register);

  final DateTime now = DateTime(2026, 9, 13, 15, 30);

  DateTime dayAt(int daysAgo, {int hour = 12, int minute = 0}) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  late SqliteDatabase database;
  late SqliteSalesReportRepository reports;
  late SeededSales seed;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    reports = SqliteSalesReportRepository(database: database);
    seed = SeededSales(database);
  });

  tearDown(() async {
    await database.close();
  });

  Future<List<SalesBill>> search(BillSearchQuery query) async {
    final List<SalesBill>? value = (await reports.searchBills(query))
        .valueOrNull;
    expect(value, isNotNull, reason: 'the search failed');
    return value!;
  }

  List<String> numbersOf(List<SalesBill> bills) =>
      bills.map((SalesBill bill) => bill.orderNumber).toList();

  group('the repository search', () {
    test('an empty query matches every settled bill, newest first', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 11),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      expect(numbersOf(await search(BillSearchQuery.none)), <String>[
        '20260913-0002',
        '20260913-0001',
      ]);
    });

    test('a cancelled bill is never a search result', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        status: OrderStatus.completed,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 13),
        status: OrderStatus.cancelled,
        subtotal: '999.00',
        tax: '0.00',
        total: '999.00',
      );

      expect(numbersOf(await search(BillSearchQuery.none)), <String>[
        '20260913-0001',
      ]);
    });

    test('by full bill number', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 13),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> found = await search(
        const BillSearchQuery(orderNumber: '20260913-0002'),
      );
      expect(numbersOf(found), <String>['20260913-0002']);
    });

    test('by a fragment of the bill number, matched anywhere', () async {
      await seed.bill(
        orderNumber: '20260913-0042',
        at: dayAt(0),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0007',
        at: dayAt(0, hour: 13),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      expect(
        numbersOf(await search(const BillSearchQuery(orderNumber: '0042'))),
        <String>['20260913-0042'],
      );
    });

    test('by customer phone, excluding walk-ins', () async {
      final String customerId = await seed.customer(
        phone: '9876543210',
        name: 'Ravi',
      );
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        customerId: customerId,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      // A walk-in on the same day.
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> found = await search(
        const BillSearchQuery(customerPhone: '9876543210'),
      );
      expect(numbersOf(found), <String>['20260913-0001']);
      expect(found.single.customerName, 'Ravi');
    });

    test('by a fragment of the phone', () async {
      final String customerId = await seed.customer(phone: '9876543210');
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        customerId: customerId,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      expect(
        numbersOf(await search(const BillSearchQuery(customerPhone: '6543'))),
        <String>['20260913-0001'],
      );
    });

    test('by order type', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        orderType: OrderType.dineIn,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        orderType: OrderType.delivery,
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      expect(
        numbersOf(
          await search(const BillSearchQuery(orderType: OrderType.delivery)),
        ),
        <String>['20260913-0002'],
      );
    });

    test('by date range', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260912-0001',
        at: dayAt(1),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> found = await search(
        BillSearchQuery(range: ReportPeriod.yesterday.resolve(now)),
      );
      expect(numbersOf(found), <String>['20260912-0001']);
    });

    test('criteria combine', () async {
      final String customerId = await seed.customer(phone: '9876543210');
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        orderType: OrderType.delivery,
        customerId: customerId,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      // Same phone, wrong type.
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        orderType: OrderType.dineIn,
        customerId: customerId,
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> found = await search(
        BillSearchQuery(
          customerPhone: '9876543210',
          orderType: OrderType.delivery,
          range: DateRange.day(now),
        ),
      );
      expect(numbersOf(found), <String>['20260913-0001']);
    });

    test(
      'a search with no match returns an empty list, not a failure',
      () async {
        await seed.bill(
          orderNumber: '20260913-0001',
          at: dayAt(0),
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );

        expect(
          await search(const BillSearchQuery(orderNumber: 'NOPE')),
          isEmpty,
        );
      },
    );

    test('results carry the bill figures, payment and refund state', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        paymentMethod: PaymentMethod.upi,
        kotNumber: 'K-1',
        subtotal: '150.00',
        tax: '0.00',
        total: '150.00',
      );

      final SalesBill bill = (await search(BillSearchQuery.none)).single;
      expect(bill.total, Money.parse('150.00'));
      expect(bill.paymentMethod, PaymentMethod.upi);
      expect(bill.kotNumber, 'K-1');
      expect(bill.isRefunded, isFalse);
    });
  });

  group('the controller', () {
    OrderHistoryController controllerFor() {
      final OrderHistoryController controller = OrderHistoryController(
        reportRepository: reports,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('opens on the last seven days and lists recent bills', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      // Older than a week: excluded from the default view.
      await seed.bill(
        orderNumber: '20260901-0001',
        at: dayAt(12),
        subtotal: '900.00',
        tax: '0.00',
        total: '900.00',
      );

      final OrderHistoryController controller = controllerFor();
      await controller.load();

      expect(controller.period, ReportPeriod.last7Days);
      expect(numbersOf(controller.results), <String>['20260913-0001']);
    });

    test('a bill number search finds an older bill across any date', () async {
      await seed.bill(
        orderNumber: '20260901-0001',
        at: dayAt(12),
        subtotal: '900.00',
        tax: '0.00',
        total: '900.00',
      );

      final OrderHistoryController controller = controllerFor();
      await controller.load();
      // Not in the default week.
      expect(controller.results, isEmpty);
      expect(controller.isEmpty, isTrue);

      controller.setOrderNumber('20260901-0001');
      await controller.selectPeriod(null); // any date
      await controller.search();

      expect(numbersOf(controller.results), <String>['20260901-0001']);
    });

    test('an order-type filter narrows and re-searches', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        orderType: OrderType.dineIn,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        orderType: OrderType.takeaway,
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final OrderHistoryController controller = controllerFor();
      await controller.load();
      expect(controller.results, hasLength(2));

      await controller.selectOrderType(OrderType.takeaway);

      expect(numbersOf(controller.results), <String>['20260913-0002']);
    });
  });
}
