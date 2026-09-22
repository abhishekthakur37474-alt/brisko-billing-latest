import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/bill_line_snapshot.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/item_sales_row.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/report_period.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/counting_database.dart';
import '../helpers/fixtures.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// The aggregate reads behind every report, against the real schema.
///
/// ## Why these run against SQLite rather than a fake
///
/// Every figure a report shows is produced by a `GROUP BY` over integer paise columns. A
/// fake repository would let the queries be wrong in exactly the ways that matter — a
/// cancelled bill counted, a pending tender treated as money in, a `LEFT JOIN` that
/// silently became an inner one and dropped every walk-in bill. So the tests drive the
/// real implementation over the real migrations.
///
/// ## Why "today" is arranged rather than waited for
///
/// A fixed instant stands in for now, and bills are written at instants derived from it.
/// The suite therefore behaves the same at 00:01 as at 23:59, and in any timezone.
void main() {
  setUpAll(TestDatabase.register);

  /// The instant the tests treat as now. Local, because a trading day is local.
  final DateTime now = DateTime(2026, 9, 13, 15, 30);

  /// An instant during the local day [daysAgo] days before [now].
  DateTime dayAt(int daysAgo, {int hour = 12, int minute = 0}) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  DateRange today() => ReportPeriod.today.resolve(now)!;
  DateRange yesterday() => ReportPeriod.yesterday.resolve(now)!;
  DateRange lastSevenDays() => ReportPeriod.last7Days.resolve(now)!;

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

  /// Reads a report, failing the test rather than the assertion when the read failed.
  Future<SalesSummary> summaryOf(DateRange range) async {
    final SalesSummary? value = (await reports.loadSummary(range)).valueOrNull;
    expect(value, isNotNull, reason: 'the summary read failed');
    return value!;
  }

  Future<PaymentMix> mixOf(DateRange range) async {
    final PaymentMix? value = (await reports.loadPaymentMix(range)).valueOrNull;
    expect(value, isNotNull, reason: 'the payment read failed');
    return value!;
  }

  Future<List<ItemSalesRow>> itemsOf(DateRange range) async {
    final List<ItemSalesRow>? value = (await reports.loadItemSales(range))
        .valueOrNull;
    expect(value, isNotNull, reason: 'the item read failed');
    return value!;
  }

  Future<List<SalesBill>> billsOf(DateRange range) async {
    final List<SalesBill>? value = (await reports.loadBills(range)).valueOrNull;
    expect(value, isNotNull, reason: 'the bills read failed');
    return value!;
  }

  // ------------------------------------------------------------------- empty ---

  group('an empty database', () {
    test('reports no sales rather than failing', () async {
      final SalesSummary summary = await summaryOf(today());

      expect(summary.billCount, 0);
      expect(summary.itemCount, 0);
      expect(summary.grossSales, Money.zero);
      expect(summary.subtotal, Money.zero);
      expect(summary.taxTotal, Money.zero);
      expect(summary.discountTotal, Money.zero);
      expect(summary.isEmpty, isTrue);
    });

    test('reports no bills, no items and no takings', () async {
      expect(await billsOf(today()), isEmpty);
      expect(await itemsOf(today()), isEmpty);

      final PaymentMix mix = await mixOf(today());
      expect(mix.isEmpty, isTrue);
      expect(mix.total, Money.zero);
      // Every method still answers, at zero.
      for (final PaymentMethod method in PaymentMethod.values) {
        expect(mix.amountFor(method), Money.zero);
        expect(mix.countFor(method), 0);
      }
    });

    test(
      'an average bill value with no bills is not a division by zero',
      () async {
        final SalesSummary summary = await summaryOf(today());
        expect(summary.averageBillValue, Money.zero);
      },
    );
  });

  // ---------------------------------------------------------------- filtering ---

  group('date filtering', () {
    setUp(() async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 10),
        total: '100.00',
        subtotal: '100.00',
        tax: '0.00',
      );
      await seed.bill(
        orderNumber: '20260912-0001',
        at: dayAt(1, hour: 19),
        total: '200.00',
        subtotal: '200.00',
        tax: '0.00',
      );
      await seed.bill(
        orderNumber: '20260909-0001',
        at: dayAt(4, hour: 13),
        total: '400.00',
        subtotal: '400.00',
        tax: '0.00',
      );
      await seed.bill(
        orderNumber: '20260901-0001',
        at: dayAt(12, hour: 13),
        total: '800.00',
        subtotal: '800.00',
        tax: '0.00',
      );
    });

    test("today shows today's bill", () async {
      final SalesSummary summary = await summaryOf(today());

      expect(summary.billCount, 1);
      expect(summary.grossSales, Money.parse('100.00'));

      final List<SalesBill> bills = await billsOf(today());
      expect(bills, hasLength(1));
      expect(bills.single.orderNumber, '20260913-0001');
    });

    test('an older bill is excluded from today', () async {
      final List<SalesBill> bills = await billsOf(today());

      expect(
        bills.map((SalesBill bill) => bill.orderNumber),
        isNot(contains('20260912-0001')),
      );
      // And its money is not in today's total either.
      final SalesSummary summary = await summaryOf(today());
      expect(summary.grossSales, Money.parse('100.00'));
    });

    test('yesterday shows only the previous day', () async {
      final SalesSummary summary = await summaryOf(yesterday());

      expect(summary.billCount, 1);
      expect(summary.grossSales, Money.parse('200.00'));

      final List<SalesBill> bills = await billsOf(yesterday());
      expect(bills.single.orderNumber, '20260912-0001');
    });

    test('last 7 days covers this day and the six before it', () async {
      final SalesSummary summary = await summaryOf(lastSevenDays());

      // Today, yesterday and four days ago. Not the bill from twelve days ago.
      expect(summary.billCount, 3);
      expect(summary.grossSales, Money.parse('700.00'));

      final List<SalesBill> bills = await billsOf(lastSevenDays());
      expect(
        bills.map((SalesBill bill) => bill.orderNumber),
        isNot(contains('20260901-0001')),
      );
    });

    test('a custom range reports exactly the days chosen', () async {
      final DateRange range = DateRange.spanning(
        firstInstant: dayAt(4),
        lastInstant: dayAt(1),
      );

      final SalesSummary summary = await summaryOf(range);

      // Four days ago and yesterday, not today.
      expect(summary.billCount, 2);
      expect(summary.grossSales, Money.parse('600.00'));

      final List<SalesBill> bills = await billsOf(range);
      expect(bills.map((SalesBill bill) => bill.orderNumber), <String>[
        '20260912-0001',
        '20260909-0001',
      ]);
    });

    test('a custom range of one day behaves like that day', () async {
      final DateRange range = DateRange.day(dayAt(12));
      final SalesSummary summary = await summaryOf(range);

      expect(summary.billCount, 1);
      expect(summary.grossSales, Money.parse('800.00'));
    });

    test('bills come back newest first', () async {
      final List<SalesBill> bills = await billsOf(lastSevenDays());

      expect(bills.map((SalesBill bill) => bill.orderNumber), <String>[
        '20260913-0001',
        '20260912-0001',
        '20260909-0001',
      ]);
    });
  });

  // ------------------------------------------------------------------- status ---

  group('which bills count', () {
    test('a settled bill contributes to sales', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        status: OrderStatus.completed,
        subtotal: '300.00',
        tax: '15.00',
        total: '315.00',
      );

      final SalesSummary summary = await summaryOf(today());
      expect(summary.billCount, 1);
      expect(summary.grossSales, Money.parse('315.00'));
      expect(summary.subtotal, Money.parse('300.00'));
      expect(summary.taxTotal, Money.parse('15.00'));
    });

    test('a cancelled bill contributes nothing', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        status: OrderStatus.completed,
        total: '100.00',
        subtotal: '100.00',
        tax: '0.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 13),
        status: OrderStatus.cancelled,
        total: '999.00',
        subtotal: '999.00',
        tax: '0.00',
        lines: const <BillLineSpec>[
          BillLineSpec(itemName: 'Cancelled Pizza', total: '999.00'),
        ],
      );

      final SalesSummary summary = await summaryOf(today());
      expect(summary.billCount, 1);
      expect(summary.grossSales, Money.parse('100.00'));

      // Not in the bills list, not in the item report, and its tender is not takings.
      final List<SalesBill> bills = await billsOf(today());
      expect(bills, hasLength(1));
      expect(bills.single.orderNumber, '20260913-0001');

      final List<ItemSalesRow> items = await itemsOf(today());
      expect(
        items.map((ItemSalesRow row) => row.itemName),
        isNot(contains('Cancelled Pizza')),
      );

      expect((await mixOf(today())).total, Money.parse('100.00'));
    });

    test('a draft or otherwise unsettled bill contributes nothing', () async {
      // Checkout never writes a draft row, but a record in any status short of settled
      // must not be counted as money taken. All four are checked, so no future flow can
      // start counting one by accident.
      for (final OrderStatus status in <OrderStatus>[
        OrderStatus.draft,
        OrderStatus.confirmed,
        OrderStatus.preparing,
        OrderStatus.ready,
      ]) {
        await seed.bill(
          orderNumber: '20260913-${status.name}',
          at: dayAt(0),
          status: status,
          total: '500.00',
          subtotal: '500.00',
          tax: '0.00',
          lines: <BillLineSpec>[
            BillLineSpec(itemName: 'Unsettled ${status.name}'),
          ],
        );
      }

      final SalesSummary summary = await summaryOf(today());
      expect(summary.billCount, 0);
      expect(summary.grossSales, Money.zero);
      expect(summary.itemCount, 0);
      expect(await billsOf(today()), isEmpty);
      expect(await itemsOf(today()), isEmpty);
      expect((await mixOf(today())).total, Money.zero);
    });

    test('a soft-deleted bill is gone from the reports', () async {
      final String orderId = await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        total: '100.00',
        subtotal: '100.00',
        tax: '0.00',
      );

      expect((await summaryOf(today())).billCount, 1);

      await SqliteOrderRepository(database: database).deleteOrder(orderId);

      expect((await summaryOf(today())).billCount, 0);
      expect(await billsOf(today()), isEmpty);
    });
  });

  // ----------------------------------------------------------------- payments ---

  group('payment totals', () {
    setUp(() async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        paymentMethod: PaymentMethod.cash,
        subtotal: '120.00',
        tax: '0.00',
        total: '120.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        paymentMethod: PaymentMethod.cash,
        subtotal: '80.50',
        tax: '0.00',
        total: '80.50',
      );
      await seed.bill(
        orderNumber: '20260913-0003',
        at: dayAt(0, hour: 11),
        paymentMethod: PaymentMethod.upi,
        subtotal: '340.25',
        tax: '0.00',
        total: '340.25',
      );
      await seed.bill(
        orderNumber: '20260913-0004',
        at: dayAt(0, hour: 12),
        paymentMethod: PaymentMethod.card,
        subtotal: '999.99',
        tax: '0.00',
        total: '999.99',
      );
      await seed.bill(
        orderNumber: '20260913-0005',
        at: dayAt(0, hour: 13),
        paymentMethod: PaymentMethod.other,
        subtotal: '55.05',
        tax: '0.00',
        total: '55.05',
      );
    });

    test('the cash total is the sum of the cash tenders', () async {
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.cash),
        Money.parse('200.50'),
      );
      expect((await mixOf(today())).countFor(PaymentMethod.cash), 2);
    });

    test('the UPI total is correct', () async {
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.upi),
        Money.parse('340.25'),
      );
      expect((await mixOf(today())).countFor(PaymentMethod.upi), 1);
    });

    test('the card total is correct', () async {
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.card),
        Money.parse('999.99'),
      );
    });

    test('the other total is correct', () async {
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.other),
        Money.parse('55.05'),
      );
    });

    test('several methods aggregate to the day\'s takings', () async {
      final PaymentMix mix = await mixOf(today());

      // 200.50 + 340.25 + 999.99 + 55.05, to the paisa.
      expect(mix.total, Money.parse('1595.79'));
      expect(mix.tenderCount, 5);
      // And the takings agree with what was billed.
      expect(mix.total, (await summaryOf(today())).grossSales);
    });

    test('all four methods are reported on, none of them invented', () async {
      expect(PaymentMix.methods, PaymentMethod.values);
      expect(PaymentMix.methods, hasLength(4));
      expect(
        PaymentMix.methods.map((PaymentMethod m) => m.name),
        containsAll(<String>['cash', 'upi', 'card', 'other']),
      );
    });

    test('a tender that has not landed is not money in', () async {
      await seed.bill(
        orderNumber: '20260913-0006',
        at: dayAt(0, hour: 14),
        paymentMethod: PaymentMethod.upi,
        paymentStatus: PaymentStatus.pending,
        subtotal: '700.00',
        tax: '0.00',
        total: '700.00',
      );

      // The bill is a sale, because it was settled. The pending attempt is not takings.
      expect((await summaryOf(today())).billCount, 6);
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.upi),
        Money.parse('340.25'),
      );
    });

    test('a bill with no recorded tender is reported without one', () async {
      await seed.bill(
        orderNumber: '20260913-0007',
        at: dayAt(0, hour: 15),
        paymentMethod: null,
        subtotal: '10.00',
        tax: '0.00',
        total: '10.00',
      );

      final SalesBill bill = (await billsOf(today()))
          .firstWhere((SalesBill b) => b.orderNumber == '20260913-0007');

      // Null, not a guess at cash.
      expect(bill.paymentMethod, isNull);
    });

    test(
      'a bill settled with two tenders counts each under its own method',
      () async {
        final String orderId = await seed.bill(
          orderNumber: '20260913-0008',
          at: dayAt(0, hour: 16),
          paymentMethod: PaymentMethod.cash,
          paymentAmount: '30.00',
          subtotal: '50.00',
          tax: '0.00',
          total: '50.00',
        );
        await seed.payments.record(
          Fixtures.payment(
            orderId: orderId,
            method: PaymentMethod.upi,
            amount: '20.00',
            createdAt: dayAt(0, hour: 16, minute: 1),
          ),
        );

        final PaymentMix mix = await mixOf(today());
        expect(mix.amountFor(PaymentMethod.cash), Money.parse('230.50'));
        expect(mix.amountFor(PaymentMethod.upi), Money.parse('360.25'));

        // The bills list still names one method: the earliest, as the receipt printed it.
        final SalesBill bill = (await billsOf(today()))
            .firstWhere((SalesBill b) => b.orderNumber == '20260913-0008');
        expect(bill.paymentMethod, PaymentMethod.cash);
      },
    );

    test('a tender against a bill outside the range is excluded', () async {
      await seed.bill(
        orderNumber: '20260912-0001',
        at: dayAt(1),
        paymentMethod: PaymentMethod.card,
        subtotal: '1000.00',
        tax: '0.00',
        total: '1000.00',
      );

      expect(
        (await mixOf(today())).amountFor(PaymentMethod.card),
        Money.parse('999.99'),
      );
      expect(
        (await mixOf(yesterday())).amountFor(PaymentMethod.card),
        Money.parse('1000.00'),
      );
    });
  });

  // -------------------------------------------------------------- bill counts ---

  group('bill count and average', () {
    test('the bill count is the number of settled bills', () async {
      for (int index = 1; index <= 7; index++) {
        await seed.bill(
          orderNumber: '20260913-000$index',
          at: dayAt(0, hour: 9, minute: index),
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );
      }
      // Plus one that does not count.
      await seed.bill(
        orderNumber: '20260913-0099',
        at: dayAt(0, hour: 17),
        status: OrderStatus.cancelled,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      final SalesSummary summary = await summaryOf(today());
      expect(summary.billCount, 7);
      expect(await billsOf(today()), hasLength(7));
    });

    test('the average bill value is integer division of the takings', () async {
      // Three bills totalling ₹100.00, which does not divide evenly into paise.
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '33.33',
        tax: '0.00',
        total: '33.33',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '33.33',
        tax: '0.00',
        total: '33.33',
      );
      await seed.bill(
        orderNumber: '20260913-0003',
        at: dayAt(0, hour: 11),
        subtotal: '33.34',
        tax: '0.00',
        total: '33.34',
      );

      final SalesSummary summary = await summaryOf(today());

      expect(summary.grossSales, Money.parse('100.00'));
      expect(summary.billCount, 3);
      // 10000 paise over three bills is 3333 paise and a third. Truncated, exactly.
      expect(summary.averageBillValue, const Money.fromPaise(3333));
      expect(summary.averageBillValue.paise, 3333);
      // And it is genuinely below the true mean rather than rounded up past it.
      expect(summary.averageBillValue * 3 <= summary.grossSales, isTrue);
    });

    test('an average that divides evenly is exact', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '150.00',
        tax: '0.00',
        total: '150.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '250.00',
        tax: '0.00',
        total: '250.00',
      );

      final SalesSummary summary = await summaryOf(today());
      expect(summary.averageBillValue, Money.parse('200.00'));
    });

    test('the discount and tax columns are summed as stored', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '400.00',
        discount: '40.00',
        tax: '18.00',
        total: '378.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '100.00',
        discount: '0.00',
        tax: '5.00',
        total: '105.00',
      );

      final SalesSummary summary = await summaryOf(today());
      expect(summary.subtotal, Money.parse('500.00'));
      expect(summary.discountTotal, Money.parse('40.00'));
      expect(summary.taxTotal, Money.parse('18.00') + Money.parse('5.00'));
      expect(summary.grossSales, Money.parse('483.00'));
      // The stored gross is the sum of the stored parts, which is worth checking once:
      // it is the arithmetic every figure on the screen rests on.
      expect(
        summary.subtotal - summary.discountTotal + summary.taxTotal,
        summary.grossSales,
      );
    });
  });

  // ---------------------------------------------------------------- item sales ---

  group('item-wise sales', () {
    test('quantities aggregate across bills', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Test Pizza',
            variantName: 'Medium',
            quantity: 2,
            unitPrice: '100.00',
            total: '200.00',
          ),
        ],
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '300.00',
        tax: '0.00',
        total: '300.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Test Pizza',
            variantName: 'Medium',
            quantity: 3,
            unitPrice: '100.00',
            total: '300.00',
          ),
        ],
      );

      final List<ItemSalesRow> rows = await itemsOf(today());

      expect(rows, hasLength(1));
      expect(rows.single.displayName, 'Test Pizza (Medium)');
      expect(rows.single.quantitySold, 5);
    });

    test('sales amounts aggregate across bills', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '250.50',
        tax: '0.00',
        total: '250.50',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Test Pizza',
            quantity: 1,
            unitPrice: '250.50',
            total: '250.50',
          ),
        ],
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '501.00',
        tax: '0.00',
        total: '501.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Test Pizza',
            quantity: 2,
            unitPrice: '250.50',
            total: '501.00',
          ),
        ],
      );

      final List<ItemSalesRow> rows = await itemsOf(today());

      expect(rows.single.quantitySold, 3);
      expect(rows.single.salesAmount, Money.parse('751.50'));
    });

    test(
      'sizes are reported separately, because that is what was priced',
      () async {
        await seed.bill(
          orderNumber: '20260913-0001',
          at: dayAt(0, hour: 9),
          subtotal: '500.00',
          tax: '0.00',
          total: '500.00',
          lines: const <BillLineSpec>[
            BillLineSpec(
              variantName: 'Medium',
              quantity: 1,
              unitPrice: '200.00',
              total: '200.00',
            ),
            BillLineSpec(
              variantName: 'Large',
              quantity: 1,
              unitPrice: '300.00',
              total: '300.00',
            ),
          ],
        );

        final List<ItemSalesRow> rows = await itemsOf(today());

        expect(rows, hasLength(2));
        // Biggest earner first.
        expect(rows.first.displayName, 'Test Pizza (Large)');
        expect(rows.last.displayName, 'Test Pizza (Medium)');
      },
    );

    test('an item with no size groups under its own name', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '120.00',
        tax: '0.00',
        total: '120.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Cold Drink',
            variantName: null,
            quantity: 2,
            unitPrice: '60.00',
            total: '120.00',
          ),
        ],
      );

      final List<ItemSalesRow> rows = await itemsOf(today());
      expect(rows.single.itemName, 'Cold Drink');
      expect(rows.single.variantName, isNull);
      expect(rows.single.displayName, 'Cold Drink');
    });

    test('units sold on the summary matches the item report', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '700.00',
        tax: '0.00',
        total: '700.00',
        lines: const <BillLineSpec>[
          BillLineSpec(quantity: 3, unitPrice: '100.00', total: '300.00'),
          BillLineSpec(
            itemName: 'Garlic Bread',
            variantName: null,
            quantity: 4,
            unitPrice: '100.00',
            total: '400.00',
          ),
        ],
      );

      final SalesSummary summary = await summaryOf(today());
      final List<ItemSalesRow> rows = await itemsOf(today());

      expect(summary.itemCount, 7);
      expect(
        rows.fold<int>(
          0,
          (int sum, ItemSalesRow row) => sum + row.quantitySold,
        ),
        summary.itemCount,
      );
    });

    test('the report is capped at the limit asked for', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        subtotal: '600.00',
        tax: '0.00',
        total: '600.00',
        lines: const <BillLineSpec>[
          BillLineSpec(itemName: 'A', variantName: null, total: '100.00'),
          BillLineSpec(itemName: 'B', variantName: null, total: '200.00'),
          BillLineSpec(itemName: 'C', variantName: null, total: '300.00'),
        ],
      );

      final List<ItemSalesRow> rows = (await reports.loadItemSales(
        today(),
        limit: 2,
      )).valueOrNull!;

      expect(rows, hasLength(2));
      expect(rows.map((ItemSalesRow row) => row.itemName), <String>['C', 'B']);
    });
  });

  // ----------------------------------------------------------------- customers ---

  group('customers on bills', () {
    test('two customers stay separate on their own bills', () async {
      final String first = await seed.customer(
        phone: '9000000001',
        name: 'First Customer',
      );
      final String second = await seed.customer(
        phone: '9000000002',
        name: 'Second Customer',
      );

      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        customerId: first,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        customerId: second,
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> bills = await billsOf(today());

      final SalesBill firstBill = bills.firstWhere(
        (SalesBill bill) => bill.orderNumber == '20260913-0001',
      );
      final SalesBill secondBill = bills.firstWhere(
        (SalesBill bill) => bill.orderNumber == '20260913-0002',
      );

      expect(firstBill.customerPhone, '9000000001');
      expect(firstBill.customerName, 'First Customer');
      expect(firstBill.total, Money.parse('100.00'));

      expect(secondBill.customerPhone, '9000000002');
      expect(secondBill.customerName, 'Second Customer');
      expect(secondBill.total, Money.parse('200.00'));
    });

    test('a walk-in bill still appears, without a customer', () async {
      final String customerId = await seed.customer(phone: '9000000001');

      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0, hour: 9),
        customerId: customerId,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260913-0002',
        at: dayAt(0, hour: 10),
        subtotal: '200.00',
        tax: '0.00',
        total: '200.00',
      );

      final List<SalesBill> bills = await billsOf(today());

      // The join must not drop the walk-in, which an inner join would.
      expect(bills, hasLength(2));
      final SalesBill walkIn = bills.firstWhere(
        (SalesBill bill) => bill.orderNumber == '20260913-0002',
      );
      expect(walkIn.hasCustomer, isFalse);
      expect(walkIn.customerPhone, isNull);
    });

    test('the customer information is shown when one is associated', () async {
      final String customerId = await seed.customer(
        phone: '9876543210',
        name: 'Named Customer',
      );
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        customerId: customerId,
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      final SalesBill bill = (await billsOf(today())).single;
      expect(bill.hasCustomer, isTrue);
      expect(bill.customerPhone, '9876543210');
      expect(bill.customerName, 'Named Customer');
    });

    test('a name without a phone is shown on the bill list', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        customerName: 'Ravi',
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      final SalesBill bill = (await billsOf(today())).single;
      expect(bill.hasCustomer, isTrue);
      expect(bill.customerPhone, isNull);
      expect(bill.customerName, 'Ravi');
    });
  });

  // ------------------------------------------------------------------ kot number ---

  group('kitchen slip numbers', () {
    test('the slip number is shown when one was raised', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        kotNumber: 'K20260913-0001',
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      final SalesBill bill = (await billsOf(today())).single;
      expect(bill.hasKotNumber, isTrue);
      expect(bill.kotNumber, 'K20260913-0001');
    });

    test('a bill with no slip is reported without one', () async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );

      final SalesBill bill = (await billsOf(today())).single;
      expect(bill.hasKotNumber, isFalse);
      expect(bill.kotNumber, isNull);
    });
  });

  // ------------------------------------------------------- history immutability ---

  group('history survives the menu changing', () {
    /// Creates a real menu item and a bill that sold it, and returns both ids.
    Future<({String menuItemId, String orderId})> soldItem() async {
      final SqliteMenuRepository menu = SqliteMenuRepository(
        database: database,
      );

      final MenuCategory category = Fixtures.category(name: 'Report Category');
      await menu.saveCategory(category);

      final MenuItem item = Fixtures.menuItem(
        id: EntityId.generate(prefix: 'item'),
        categoryId: category.id,
        name: 'Original Name',
        basePrice: '200.00',
      );
      await menu.saveItem(item);

      final String orderId = await seed.bill(
        orderNumber: '20260913-0001',
        at: dayAt(0),
        subtotal: '400.00',
        tax: '0.00',
        total: '400.00',
        lines: <BillLineSpec>[
          BillLineSpec(
            itemName: 'Original Name',
            variantName: null,
            quantity: 2,
            unitPrice: '200.00',
            total: '400.00',
            menuItemId: item.id,
          ),
        ],
      );

      return (menuItemId: item.id, orderId: orderId);
    }

    test('a renamed menu item does not rename what was sold', () async {
      final ({String menuItemId, String orderId}) sold = await soldItem();
      final SqliteMenuRepository menu = SqliteMenuRepository(
        database: database,
      );

      final MenuItem stored = (await menu.findItem(sold.menuItemId))
          .valueOrNull!;
      await menu.saveItem(
        stored.copyWith(name: 'Renamed Completely', updatedAt: DateTime.now()),
      );

      // The menu really did change.
      expect(
        (await menu.findItem(sold.menuItemId)).valueOrNull!.name,
        'Renamed Completely',
      );

      // The report did not.
      final List<ItemSalesRow> rows = await itemsOf(today());
      expect(rows.single.itemName, 'Original Name');
      expect(rows.single.quantitySold, 2);
    });

    test('a repriced menu item does not reprice what was sold', () async {
      final ({String menuItemId, String orderId}) sold = await soldItem();
      final SqliteMenuRepository menu = SqliteMenuRepository(
        database: database,
      );

      final MenuItem stored = (await menu.findItem(sold.menuItemId))
          .valueOrNull!;
      await menu.saveItem(
        stored.copyWith(
          basePrice: Money.parse('999.00'),
          updatedAt: DateTime.now(),
        ),
      );

      expect(
        (await menu.findItem(sold.menuItemId)).valueOrNull!.basePrice,
        Money.parse('999.00'),
      );

      // Still the price that was charged.
      expect(
        (await itemsOf(today())).single.salesAmount,
        Money.parse('400.00'),
      );
      expect((await summaryOf(today())).grossSales, Money.parse('400.00'));
      expect((await billsOf(today())).single.total, Money.parse('400.00'));
    });

    test('a menu item made unavailable does not remove its sales', () async {
      final ({String menuItemId, String orderId}) sold = await soldItem();
      final SqliteMenuRepository menu = SqliteMenuRepository(
        database: database,
      );

      final MenuItem stored = (await menu.findItem(sold.menuItemId))
          .valueOrNull!;
      await menu.saveItem(
        stored.copyWith(isAvailable: false, updatedAt: DateTime.now()),
      );

      expect((await itemsOf(today())).single.quantitySold, 2);
      expect((await summaryOf(today())).grossSales, Money.parse('400.00'));
    });

    test(
      'a soft-deleted menu item does not delete the bills that sold it',
      () async {
        final ({String menuItemId, String orderId}) sold = await soldItem();
        final SqliteMenuRepository menu = SqliteMenuRepository(
          database: database,
        );

        await menu.deleteItem(sold.menuItemId);

        // Gone from the menu.
        expect(
          (await menu.loadItems()).valueOrNull!.map((MenuItem i) => i.id),
          isNot(contains(sold.menuItemId)),
        );

        // Present in the reports, in full.
        expect(await billsOf(today()), hasLength(1));
        expect((await summaryOf(today())).grossSales, Money.parse('400.00'));
        final List<ItemSalesRow> rows = await itemsOf(today());
        expect(rows.single.itemName, 'Original Name');
        expect(rows.single.salesAmount, Money.parse('400.00'));

        // And the stored bill still opens with its original lines.
        final List<BillLineSnapshot> lines = (await SqliteOrderRepository(
          database: database,
        ).loadBillLines(sold.orderId)).valueOrNull!;
        expect(lines.single.displayName, 'Original Name');
        expect(lines.single.unitPrice, Money.parse('200.00'));
        expect(lines.single.lineTotal, Money.parse('400.00'));
      },
    );

    test(
      'the bill detail behind a report row is the persisted snapshot',
      () async {
        await seed.bill(
          orderNumber: '20260913-0001',
          at: dayAt(0),
          orderType: OrderType.dineIn,
          subtotal: '230.00',
          discount: '10.00',
          tax: '11.00',
          total: '231.00',
          lines: const <BillLineSpec>[
            BillLineSpec(
              itemName: 'Snapshot Pizza',
              variantName: 'Large',
              quantity: 1,
              unitPrice: '200.00',
              total: '230.00',
              optionName: 'Extra Cheese',
              optionPrice: '30.00',
            ),
          ],
        );

        final SalesBill row = (await billsOf(today())).single;

        final List<BillLineSnapshot> lines = (await SqliteOrderRepository(
          database: database,
        ).loadBillLines(row.orderId)).valueOrNull!;

        expect(lines, hasLength(1));
        expect(lines.single.item.itemNameSnapshot, 'Snapshot Pizza');
        expect(lines.single.item.variantNameSnapshot, 'Large');
        expect(lines.single.quantity, 1);
        expect(lines.single.unitPrice, Money.parse('200.00'));
        expect(lines.single.lineTotal, Money.parse('230.00'));
        expect(lines.single.options.single.optionNameSnapshot, 'Extra Cheese');
        expect(lines.single.options.single.price, Money.parse('30.00'));

        expect(row.order.subtotal, Money.parse('230.00'));
        expect(row.order.discountAmount, Money.parse('10.00'));
        expect(row.order.taxAmount, Money.parse('11.00'));
        expect(row.total, Money.parse('231.00'));
        expect(row.orderType, OrderType.dineIn);
      },
    );
  });

  // -------------------------------------------------------------- performance ---

  group('query count', () {
    /// Reads every report over [billCount] bills and returns the statements run.
    ///
    /// The database is driven through a counting factory, so this is a count of real
    /// SQL statements rather than an assumption about them.
    Future<List<String>> statementsFor(int billCount) async {
      // A file of its own rather than the in-memory path. sqflite hands back the same
      // handle for a given path while it is open, and every other test here is already
      // holding the in-memory one, so sharing it would have two arrangements writing
      // into the same tables.
      final Directory directory = await Directory.systemTemp.createTemp(
        'brisko_reports_',
      );
      final CountingDatabaseFactory counting = CountingDatabaseFactory();
      final SqliteDatabase counted = SqliteDatabase(factory: counting);
      await counted.open(path: p.join(directory.path, 'counted.db'));

      try {
        final SeededSales arranged = SeededSales(counted);
        for (int index = 1; index <= billCount; index++) {
          await arranged.bill(
            orderNumber: '20260913-${index.toString().padLeft(4, '0')}',
            at: dayAt(0, hour: 9, minute: index % 60),
            kotNumber: 'K20260913-${index.toString().padLeft(4, '0')}',
            subtotal: '100.00',
            tax: '0.00',
            total: '100.00',
            lines: <BillLineSpec>[
              BillLineSpec(itemName: 'Item ${index % 5}', variantName: null),
            ],
          );
        }

        // Everything above is arrangement. Only the reads are counted.
        counting.reset();

        final SqliteSalesReportRepository countedReports =
            SqliteSalesReportRepository(database: counted);
        await countedReports.loadSummary(today());
        await countedReports.loadPaymentMix(today());
        await countedReports.loadItemSales(today());
        await countedReports.loadBills(today());

        return counting.statements;
      } finally {
        await counted.close();
        await directory.delete(recursive: true);
      }
    }

    test('a report is four statements however many bills there are', () async {
      final List<String> forOne = await statementsFor(1);
      final List<String> forSixty = await statementsFor(60);

      // One statement per report, and the same four whatever the volume. This is the
      // assertion that would fail the moment a per-bill lookup crept in.
      expect(forOne, hasLength(4));
      expect(forSixty, hasLength(4));
      expect(forSixty.length, forOne.length);
    });

    test('a large result set still comes back correct', () async {
      for (int index = 1; index <= 60; index++) {
        await seed.bill(
          orderNumber: '20260913-${index.toString().padLeft(4, '0')}',
          at: dayAt(0, hour: 9, minute: index % 60),
          kotNumber: 'K20260913-${index.toString().padLeft(4, '0')}',
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
          lines: <BillLineSpec>[
            BillLineSpec(
              itemName: 'Item ${index % 5}',
              variantName: null,
              quantity: 1,
              unitPrice: '100.00',
              total: '100.00',
            ),
          ],
        );
      }

      final SalesSummary summary = await summaryOf(today());
      expect(summary.billCount, 60);
      expect(summary.itemCount, 60);
      expect(summary.grossSales, Money.parse('6000.00'));
      expect(await billsOf(today()), hasLength(60));
      // Five distinct item names across the sixty bills.
      expect(await itemsOf(today()), hasLength(5));
      expect(
        (await mixOf(today())).amountFor(PaymentMethod.cash),
        Money.parse('6000.00'),
      );
    });

    test('the bills list is capped at the limit asked for', () async {
      for (int index = 1; index <= 5; index++) {
        await seed.bill(
          orderNumber: '20260913-000$index',
          at: dayAt(0, hour: 9, minute: index),
          subtotal: '100.00',
          tax: '0.00',
          total: '100.00',
        );
      }

      final List<SalesBill> limited = (await reports.loadBills(
        today(),
        limit: 2,
      )).valueOrNull!;

      expect(limited, hasLength(2));
      // The limit caps the list, not the totals.
      expect((await summaryOf(today())).billCount, 5);
    });
  });
}
