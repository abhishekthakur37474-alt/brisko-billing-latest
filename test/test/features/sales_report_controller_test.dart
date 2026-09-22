import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/reports/domain/models/bill_search_query.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/item_sales_row.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/report_period.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:brisko_billing/features/reports/domain/repositories/sales_report_repository.dart';
import 'package:brisko_billing/features/reports/presentation/controllers/sales_report_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

/// The Reports screen's state, without a database.
///
/// The repository is substituted here on purpose. What is being checked is the controller's
/// own behaviour — which range it asks about, what it does with a failure, whether it can be
/// made to run two reads at once — and each of those is easier to provoke against a stub
/// than against SQLite. The queries themselves are covered against the real schema in
/// `sales_report_repository_test.dart`.
void main() {
  /// A fixed instant standing in for now, so "today" is the same in every run and every
  /// timezone.
  final DateTime now = DateTime(2026, 9, 13, 15, 30);

  late _StubReportRepository repository;
  late SalesReportController controller;

  setUp(() {
    repository = _StubReportRepository();
    controller = SalesReportController(
      reportRepository: repository,
      clock: () => now,
    );
  });

  tearDown(() => controller.dispose());

  group('the range it opens on', () {
    test('is today, taken from the injected clock', () {
      expect(controller.period, ReportPeriod.today);
      expect(controller.range, DateRange.day(now));
    });

    test('is what the first read asks about', () async {
      await controller.load();

      expect(repository.summaryRanges, <DateRange>[DateRange.day(now)]);
    });
  });

  group('filters', () {
    test('yesterday reads the previous day', () async {
      await controller.selectPeriod(ReportPeriod.yesterday);

      expect(controller.period, ReportPeriod.yesterday);
      expect(controller.range.firstDay, DateTime(2026, 9, 12));
      expect(controller.range.dayCount, 1);
      expect(repository.summaryRanges.last, controller.range);
    });

    test('last 7 days reads the week ending today', () async {
      await controller.selectPeriod(ReportPeriod.last7Days);

      expect(controller.range.firstDay, DateTime(2026, 9, 7));
      expect(controller.range.lastDay, DateTime(2026, 9, 13));
      expect(controller.range.dayCount, 7);
    });

    test('a custom range reads exactly the days chosen', () async {
      await controller.selectCustomRange(
        firstDay: DateTime(2026, 8, 30),
        lastDay: DateTime(2026, 9, 2),
      );

      expect(controller.period, ReportPeriod.custom);
      expect(controller.range.firstDay, DateTime(2026, 8, 30));
      expect(controller.range.lastDay, DateTime(2026, 9, 2));
      expect(controller.range.dayCount, 4);
      expect(repository.summaryRanges.last, controller.range);
    });

    test('selecting Custom without dates leaves the report alone', () async {
      await controller.load();
      final int readsSoFar = repository.summaryRanges.length;

      await controller.selectPeriod(ReportPeriod.custom);

      // No read, and the previous range is still what is on screen.
      expect(repository.summaryRanges, hasLength(readsSoFar));
      expect(controller.period, ReportPeriod.today);
    });

    test('reselecting the same period does not read again', () async {
      await controller.selectPeriod(ReportPeriod.yesterday);
      final int readsSoFar = repository.summaryRanges.length;

      await controller.selectPeriod(ReportPeriod.yesterday);

      expect(repository.summaryRanges, hasLength(readsSoFar));
    });

    test('every report is asked about the same range', () async {
      await controller.selectPeriod(ReportPeriod.last7Days);

      expect(repository.summaryRanges.last, controller.range);
      expect(repository.mixRanges.last, controller.range);
      expect(repository.itemRanges.last, controller.range);
      expect(repository.billRanges.last, controller.range);
    });
  });

  group('what it holds', () {
    test('the figures the repository returned, unaltered', () async {
      repository.summary = const SalesSummary(
        billCount: 4,
        itemCount: 11,
        subtotal: Money.fromPaise(120000),
        discountTotal: Money.fromPaise(2000),
        taxTotal: Money.fromPaise(5900),
        grossSales: Money.fromPaise(123900),
      );
      repository.mix = PaymentMix(
        amounts: <PaymentMethod, Money>{
          PaymentMethod.cash: const Money.fromPaise(100000),
          PaymentMethod.upi: const Money.fromPaise(23900),
        },
        counts: <PaymentMethod, int>{
          PaymentMethod.cash: 3,
          PaymentMethod.upi: 1,
        },
      );
      repository.items = const <ItemSalesRow>[
        ItemSalesRow(
          itemName: 'Test Pizza',
          variantName: 'Medium',
          quantitySold: 11,
          salesAmount: Money.fromPaise(120000),
        ),
      ];
      repository.bills = <SalesBill>[
        SalesBill(
          order: Fixtures.order(
            orderNumber: '20260913-0001',
            status: OrderStatus.completed,
            createdAt: now,
          ),
          paymentMethod: PaymentMethod.cash,
        ),
      ];

      await controller.load();

      expect(controller.hasLoaded, isTrue);
      expect(controller.hasError, isFalse);
      expect(controller.isEmpty, isFalse);
      expect(controller.summary.billCount, 4);
      expect(controller.summary.grossSales, const Money.fromPaise(123900));
      // Integer division of the persisted paise, not a rounded float.
      expect(controller.summary.averageBillValue, const Money.fromPaise(30975));
      expect(
        controller.paymentMix.amountFor(PaymentMethod.cash),
        const Money.fromPaise(100000),
      );
      expect(controller.itemSales, hasLength(1));
      expect(controller.bills, hasLength(1));
    });

    test('an empty range is reported as empty, not as an error', () async {
      await controller.load();

      expect(controller.hasError, isFalse);
      expect(controller.isEmpty, isTrue);
      expect(controller.summary, SalesSummary.empty);
      expect(controller.bills, isEmpty);
      expect(controller.itemSales, isEmpty);
      expect(controller.paymentMix.isEmpty, isTrue);
    });

    test('nothing is loaded before the first read', () {
      expect(controller.hasLoaded, isFalse);
      expect(controller.isEmpty, isFalse);
      expect(controller.hasError, isFalse);
    });
  });

  group('failure', () {
    test('a failed summary read shows the message and no figures', () async {
      repository.summary = const SalesSummary(
        billCount: 9,
        itemCount: 9,
        subtotal: Money.fromPaise(900),
        discountTotal: Money.zero,
        taxTotal: Money.zero,
        grossSales: Money.fromPaise(900),
      );
      repository.failSummary = const LocalStorageFailure('Could not read.');

      await controller.load();

      expect(controller.hasError, isTrue);
      expect(controller.errorMessage, 'Could not read.');
      // No half-report left behind: a total beside an error is a total somebody quotes.
      expect(controller.summary, SalesSummary.empty);
      expect(controller.bills, isEmpty);
      expect(controller.isEmpty, isFalse);
    });

    test('a failure in any of the four reports is reported', () async {
      for (final String which in <String>['summary', 'mix', 'items', 'bills']) {
        final _StubReportRepository stub = _StubReportRepository();
        const AppFailure failure = LocalStorageFailure('Storage fault.');
        switch (which) {
          case 'summary':
            stub.failSummary = failure;
          case 'mix':
            stub.failMix = failure;
          case 'items':
            stub.failItems = failure;
          case 'bills':
            stub.failBills = failure;
        }

        final SalesReportController subject = SalesReportController(
          reportRepository: stub,
          clock: () => now,
        );
        addTearDown(subject.dispose);

        await subject.load();

        expect(subject.hasError, isTrue, reason: 'the $which read failed');
        expect(subject.errorMessage, 'Storage fault.');
      }
    });

    test('a retry after a fault clears the error and reads again', () async {
      repository.failSummary = const LocalStorageFailure('Storage fault.');
      await controller.load();
      expect(controller.hasError, isTrue);

      repository.failSummary = null;
      repository.summary = const SalesSummary(
        billCount: 1,
        itemCount: 1,
        subtotal: Money.fromPaise(500),
        discountTotal: Money.zero,
        taxTotal: Money.zero,
        grossSales: Money.fromPaise(500),
      );

      await controller.retry();

      expect(controller.hasError, isFalse);
      expect(controller.errorMessage, isNull);
      expect(controller.summary.billCount, 1);
    });
  });

  group('concurrency', () {
    test('two loads at once do not interleave', () async {
      final Future<void> first = controller.load();
      final Future<void> second = controller.load();
      await Future.wait(<Future<void>>[first, second]);

      // The second call was ignored while the first was running.
      expect(repository.summaryRanges, hasLength(1));
    });

    test(
      'a range changed mid-read is read again rather than shown stale',
      () async {
        // Start a read, then switch the filter before it finishes.
        final Future<void> reading = controller.load();
        final Future<void> switching = controller.selectPeriod(
          ReportPeriod.yesterday,
        );
        await Future.wait(<Future<void>>[reading, switching]);

        // Today first, then yesterday: the second pass covers the range actually selected.
        expect(repository.summaryRanges, <DateRange>[
          DateRange.day(now),
          ReportPeriod.yesterday.resolve(now)!,
        ]);
        expect(controller.range, ReportPeriod.yesterday.resolve(now));
        expect(controller.isLoading, isFalse);
        expect(controller.hasLoaded, isTrue);
      },
    );

    test('notifies its listeners as the read progresses', () async {
      int notifications = 0;
      controller.addListener(() => notifications++);

      await controller.load();

      // At least the start of the read and its completion.
      expect(notifications, greaterThanOrEqualTo(2));
    });
  });
}

/// A [SalesReportRepository] that returns whatever the test put in it.
///
/// Records the range of every call, which is how the filter tests check that the controller
/// asked about the days it claims to be showing.
class _StubReportRepository implements SalesReportRepository {
  SalesSummary summary = SalesSummary.empty;
  PaymentMix mix = PaymentMix.empty();
  List<ItemSalesRow> items = const <ItemSalesRow>[];
  List<SalesBill> bills = const <SalesBill>[];

  AppFailure? failSummary;
  AppFailure? failMix;
  AppFailure? failItems;
  AppFailure? failBills;

  final List<DateRange> summaryRanges = <DateRange>[];
  final List<DateRange> mixRanges = <DateRange>[];
  final List<DateRange> itemRanges = <DateRange>[];
  final List<DateRange> billRanges = <DateRange>[];

  @override
  Future<Result<SalesSummary>> loadSummary(DateRange range) async {
    summaryRanges.add(range);
    final AppFailure? failure = failSummary;
    return failure == null
        ? Ok<SalesSummary>(summary)
        : Err<SalesSummary>(failure);
  }

  @override
  Future<Result<PaymentMix>> loadPaymentMix(DateRange range) async {
    mixRanges.add(range);
    final AppFailure? failure = failMix;
    return failure == null ? Ok<PaymentMix>(mix) : Err<PaymentMix>(failure);
  }

  @override
  Future<Result<List<ItemSalesRow>>> loadItemSales(
    DateRange range, {
    int limit = 200,
  }) async {
    itemRanges.add(range);
    final AppFailure? failure = failItems;
    return failure == null
        ? Ok<List<ItemSalesRow>>(items)
        : Err<List<ItemSalesRow>>(failure);
  }

  @override
  Future<Result<List<SalesBill>>> loadBills(
    DateRange range, {
    int limit = 200,
  }) async {
    billRanges.add(range);
    final AppFailure? failure = failBills;
    return failure == null
        ? Ok<List<SalesBill>>(bills)
        : Err<List<SalesBill>>(failure);
  }

  @override
  Future<Result<List<SalesBill>>> searchBills(
    BillSearchQuery query, {
    int limit = 100,
  }) async {
    final AppFailure? failure = failBills;
    return failure == null
        ? Ok<List<SalesBill>>(bills)
        : Err<List<SalesBill>>(failure);
  }
}
