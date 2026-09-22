import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/orders/presentation/widgets/bill_detail_view.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/reports/domain/models/bill_search_query.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/item_sales_row.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:brisko_billing/features/reports/domain/repositories/sales_report_repository.dart';
import 'package:brisko_billing/features/reports/presentation/report_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

/// The Reports screen, driven through the real application.
///
/// ## Why the whole app rather than the screen alone
///
/// The screen is reached by navigating the shell, and a bill is opened from it into the same
/// dialog the customer history uses. Both of those are wiring, and wiring is exactly what a
/// widget test should exercise. So these tests build `BriskoApp` over a real in-memory
/// database, tap the navigation rail, and read what is on screen.
///
/// The bills are seeded at the real clock's today, because the screen uses the real clock.
/// Everything about *which* day a range covers is tested deterministically elsewhere; what
/// is checked here is that the screen shows what the database holds.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;

  /// A settled bill taken a few hours ago, so it is unambiguously inside today wherever
  /// the suite runs. Backed off from midnight rather than using the current instant, which
  /// would sit on the boundary when the suite runs at 00:00.
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

  /// Lets in-flight database work finish, then renders the result.
  ///
  /// A widget test body runs inside a fake-async zone where real I/O never completes, and
  /// sqflite answers from outside it. Bounded pumps interleaved with [WidgetTester.runAsync]
  /// rather than `pumpAndSettle`, which would never settle: the loading state spins an
  /// indeterminate progress indicator, so the tree is not quiescent while a read is in
  /// flight.
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

  /// Builds the app on a counter-sized display and opens Reports.
  Future<void> openReports(
    WidgetTester tester, {
    AppDependencies? dependencies,
  }) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppDependencies deps =
        dependencies ?? TestDependencies.over(database);
    await tester.pumpWidget(BriskoApp(dependencies: deps));
    await settleUi(tester);

    // The real navigation, through the shell's rail.
    await tap(tester, find.text(PosSection.reports.label));
  }

  /// The tab for [section], distinguished from body text that happens to read the same.
  Finder tabFor(ReportSection section) =>
      find.widgetWithText(Tab, section.label);

  group('an empty database', () {
    testWidgets('says so rather than showing a screen of zeroes', (
      WidgetTester tester,
    ) async {
      await openReports(tester);

      expect(find.textContaining('No sales'), findsOneWidget);
      expect(
        find.textContaining('cancelled bills are never counted'),
        findsOneWidget,
      );
      // No invented figure anywhere on it.
      expect(find.textContaining('₹'), findsNothing);
    });

    testWidgets('still offers the date filters and the four reports', (
      WidgetTester tester,
    ) async {
      await openReports(tester);

      expect(find.widgetWithText(ChoiceChip, 'Today'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Yesterday'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Last 7 days'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Custom'), findsOneWidget);

      for (final ReportSection section in ReportSection.values) {
        expect(tabFor(section), findsOneWidget);
      }
    });
  });

  group("today's sales", () {
    setUp(() async {
      final String customerId = await seed.customer(
        phone: '9876543210',
        name: 'Report Customer',
      );

      await seed.bill(
        orderNumber: '20260913-0001',
        at: todayAt(10),
        orderType: OrderType.dineIn,
        customerId: customerId,
        kotNumber: 'K-0001',
        paymentMethod: PaymentMethod.cash,
        subtotal: '400.00',
        discount: '0.00',
        tax: '0.00',
        total: '400.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Report Pizza',
            variantName: 'Large',
            quantity: 2,
            unitPrice: '200.00',
            total: '400.00',
            optionName: 'Extra Cheese',
            optionPrice: '30.00',
          ),
        ],
      );

      await seed.bill(
        orderNumber: '20260913-0002',
        at: todayAt(11),
        paymentMethod: PaymentMethod.upi,
        subtotal: '100.00',
        discount: '0.00',
        tax: '0.00',
        total: '100.00',
        lines: const <BillLineSpec>[
          BillLineSpec(
            itemName: 'Report Fries',
            variantName: null,
            quantity: 1,
            unitPrice: '100.00',
            total: '100.00',
          ),
        ],
      );

      // A cancelled bill, which must not appear in any of it.
      await seed.bill(
        orderNumber: '20260913-0003',
        at: todayAt(12),
        status: OrderStatus.cancelled,
        subtotal: '999.00',
        discount: '0.00',
        tax: '0.00',
        total: '999.00',
        lines: const <BillLineSpec>[
          BillLineSpec(itemName: 'Cancelled Item', variantName: null),
        ],
      );
    });

    testWidgets('the summary shows the takings, the count and the average', (
      WidgetTester tester,
    ) async {
      await openReports(tester);

      // ₹500.00 over two bills, averaging ₹250.00. The cancelled ₹999 is absent.
      expect(find.text('₹500.00'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      expect(find.text('₹250.00'), findsOneWidget);
      expect(find.textContaining('₹999.00'), findsNothing);
      expect(find.textContaining('Cancelled bills excluded'), findsOneWidget);
    });

    testWidgets('the bills tab lists the settled bills and what is on them', (
      WidgetTester tester,
    ) async {
      await openReports(tester);
      await tap(tester, tabFor(ReportSection.bills));

      expect(find.text('Bill 20260913-0001'), findsOneWidget);
      expect(find.text('Bill 20260913-0002'), findsOneWidget);
      // The cancelled bill is not a sale.
      expect(find.text('Bill 20260913-0003'), findsNothing);

      // Order type, payment method and the slip number, all from stored rows.
      expect(find.textContaining('Dine-in'), findsOneWidget);
      expect(find.textContaining('Cash'), findsWidgets);
      expect(find.textContaining('KOT K-0001'), findsOneWidget);

      // The customer where there is one, and an explicit walk-in where there is not.
      expect(find.textContaining('Report Customer'), findsOneWidget);
      expect(find.text('Walk-in'), findsOneWidget);
    });

    testWidgets('opening a bill shows the persisted document', (
      WidgetTester tester,
    ) async {
      await openReports(tester);
      await tap(tester, tabFor(ReportSection.bills));

      await tap(tester, find.text('Bill 20260913-0001'));

      expect(find.byType(BillDetailView), findsOneWidget);

      // The snapshot: name, size, quantity, unit price, line total and the option.
      expect(find.text('Report Pizza (Large)'), findsOneWidget);
      expect(find.text('2 x ₹200.00'), findsOneWidget);
      expect(find.textContaining('Extra Cheese'), findsOneWidget);
      expect(find.text('Grand total'), findsOneWidget);
      // The customer and how it was paid.
      expect(find.text('Paid by'), findsOneWidget);
      expect(find.textContaining('98765 43210'), findsWidgets);

      await tap(tester, find.text('Close'));
      expect(find.byType(BillDetailView), findsNothing);
    });

    testWidgets('the item sales tab reports the stored line snapshots', (
      WidgetTester tester,
    ) async {
      await openReports(tester);
      await tap(tester, tabFor(ReportSection.items));

      expect(find.text('Report Pizza (Large)'), findsOneWidget);
      expect(find.text('Report Fries'), findsOneWidget);
      expect(find.text('Cancelled Item'), findsNothing);

      // Quantity and amount columns.
      expect(find.text('Item'), findsOneWidget);
      expect(find.text('Qty'), findsOneWidget);
      expect(find.text('₹400.00'), findsOneWidget);
    });

    testWidgets('the payment tab splits the takings across all four methods', (
      WidgetTester tester,
    ) async {
      await openReports(tester);
      await tap(tester, tabFor(ReportSection.payments));

      for (final PaymentMethod method in PaymentMethod.values) {
        expect(
          find.text(method.label),
          findsWidgets,
          reason: '${method.label} must be reported even at zero',
        );
      }

      expect(find.text('₹400.00'), findsOneWidget); // cash
      expect(find.text('₹100.00'), findsOneWidget); // upi
      expect(find.text('₹0.00'), findsNWidgets(2)); // card and other
      expect(find.text('Collected'), findsOneWidget);

      // No tender the outlet does not accept.
      expect(find.textContaining('Wallet'), findsNothing);
      expect(find.textContaining('Loyalty'), findsNothing);
    });
  });

  group('date filtering on screen', () {
    setUp(() async {
      await seed.bill(
        orderNumber: '20260913-0001',
        at: todayAt(10),
        subtotal: '100.00',
        tax: '0.00',
        total: '100.00',
      );
      await seed.bill(
        orderNumber: '20260912-0001',
        at: DateTime(
          todayAt(10).year,
          todayAt(10).month,
          todayAt(10).day - 1,
          10,
        ),
        subtotal: '250.00',
        tax: '0.00',
        total: '250.00',
      );
    });

    testWidgets('switching to yesterday reads the previous day', (
      WidgetTester tester,
    ) async {
      await openReports(tester);
      expect(find.text('₹100.00'), findsWidgets);

      await tap(tester, find.widgetWithText(ChoiceChip, 'Yesterday'));

      expect(find.text('₹250.00'), findsWidgets);
      expect(find.text('₹100.00'), findsNothing);

      await tap(tester, tabFor(ReportSection.bills));
      expect(find.text('Bill 20260912-0001'), findsOneWidget);
      expect(find.text('Bill 20260913-0001'), findsNothing);
    });

    testWidgets('last 7 days covers both', (WidgetTester tester) async {
      await openReports(tester);

      await tap(tester, find.widgetWithText(ChoiceChip, 'Last 7 days'));

      expect(find.text('₹350.00'), findsWidgets);
      // And the dates covered are spelled out rather than implied by the chip.
      expect(find.textContaining('7 days'), findsWidgets);
    });

    testWidgets('a custom range can be chosen and dismissed without loss', (
      WidgetTester tester,
    ) async {
      await openReports(tester);

      await tap(tester, find.widgetWithText(ChoiceChip, 'Custom'));

      expect(find.text('Report on these dates'), findsOneWidget);

      // Dismissed. The report that was on screen is still on screen.
      await tap(tester, find.byIcon(Icons.close));

      expect(find.widgetWithText(ChoiceChip, 'Today'), findsOneWidget);
      expect(find.text('₹100.00'), findsWidgets);
    });
  });

  group('a repository fault', () {
    testWidgets('is shown in place with a retry, not thrown', (
      WidgetTester tester,
    ) async {
      final _FailingReportRepository failing = _FailingReportRepository();

      await openReports(
        tester,
        dependencies: TestDependencies.over(
          database,
          salesReportRepository: failing,
        ),
      );

      // Nothing escaped as a widget error.
      expect(tester.takeException(), isNull);

      expect(find.text('This report could not be read'), findsOneWidget);
      expect(
        find.text('The local database could not be read.'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);

      // The rest of the screen still works.
      expect(find.widgetWithText(ChoiceChip, 'Today'), findsOneWidget);
      expect(tabFor(ReportSection.summary), findsOneWidget);

      // Retrying reads again, and succeeds once the fault clears.
      failing.isBroken = false;
      await tap(tester, find.text('Try again'));

      expect(tester.takeException(), isNull);
      expect(find.text('This report could not be read'), findsNothing);
      expect(find.text('₹1234.00'), findsWidgets);
      expect(failing.attempts, greaterThanOrEqualTo(2));
    });
  });
}

/// A reports repository that fails until told not to.
///
/// Exists so the screen's failure path can be exercised without breaking a real database.
/// Every method fails together, because a storage fault does not pick one query.
class _FailingReportRepository implements SalesReportRepository {
  bool isBroken = true;

  int attempts = 0;

  static const AppFailure _failure = LocalStorageFailure(
    'The local database could not be read.',
  );

  @override
  Future<Result<SalesSummary>> loadSummary(DateRange range) async {
    attempts++;
    if (isBroken) {
      return const Err<SalesSummary>(_failure);
    }
    return const Ok<SalesSummary>(
      SalesSummary(
        billCount: 1,
        itemCount: 1,
        subtotal: Money.fromPaise(123400),
        discountTotal: Money.zero,
        taxTotal: Money.zero,
        grossSales: Money.fromPaise(123400),
      ),
    );
  }

  @override
  Future<Result<PaymentMix>> loadPaymentMix(DateRange range) async {
    if (isBroken) {
      return const Err<PaymentMix>(_failure);
    }
    return Ok<PaymentMix>(PaymentMix.empty());
  }

  @override
  Future<Result<List<ItemSalesRow>>> loadItemSales(
    DateRange range, {
    int limit = 200,
  }) async {
    if (isBroken) {
      return const Err<List<ItemSalesRow>>(_failure);
    }
    return const Ok<List<ItemSalesRow>>(<ItemSalesRow>[]);
  }

  @override
  Future<Result<List<SalesBill>>> loadBills(
    DateRange range, {
    int limit = 200,
  }) async {
    if (isBroken) {
      return const Err<List<SalesBill>>(_failure);
    }
    return const Ok<List<SalesBill>>(<SalesBill>[]);
  }

  @override
  Future<Result<List<SalesBill>>> searchBills(
    BillSearchQuery query, {
    int limit = 100,
  }) async {
    if (isBroken) {
      return const Err<List<SalesBill>>(_failure);
    }
    return const Ok<List<SalesBill>>(<SalesBill>[]);
  }
}
