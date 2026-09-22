import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/repositories/customer_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/repositories/order_repository.dart';
import 'package:brisko_billing/features/orders/presentation/widgets/bill_detail_view.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/payments/domain/repositories/payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/repositories/refund_repository.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Refunding from the stored-bill dialog, driven by tapping.
///
/// ## Why the real repositories
///
/// Nothing is stubbed except where a test is specifically about a failure, and no sample bill
/// is injected: every bill here exists because it was written to the database. An assertion
/// about what is on screen is therefore an assertion about what is stored.
///
/// ## Why database work goes through [WidgetTester.runAsync]
///
/// A widget test runs its body inside a fake-async zone where the clock is controlled and real
/// I/O never completes. sqflite answers from outside that zone, so a query awaited directly in
/// a test body would hang forever. Every database call here is therefore wrapped, which also
/// makes the boundary between "arrange the stored data" and "drive the widgets" explicit.
///
/// ## `tester.takeException()`
///
/// Every test that drives a failure asserts it is `null`. A refund that is refused has to read
/// as a notice the cashier can act on, not as a red screen or a thrown exception behind a
/// dialog.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteCustomerRepository customers;
  late SqliteRefundRepository refunds;

  final DateTime billedAt = DateTime(2026, 4, 9, 13, 30);

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    refunds = SqliteRefundRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// Lets in-flight database work finish, then renders the result.
  ///
  /// Bounded pumps interleaved with [WidgetTester.runAsync] rather than `pumpAndSettle`, which
  /// would never settle while a progress indicator is spinning.
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

  Future<String> settledBill({
    String orderNumber = '20260409-0001',
    OrderStatus status = OrderStatus.completed,
    PaymentMethod? paymentMethod = PaymentMethod.cash,
    String? customerId,
  }) async {
    return seed.bill(
      orderNumber: orderNumber,
      at: billedAt,
      status: status,
      kotNumber: 'K$orderNumber',
      paymentMethod: paymentMethod,
      customerId: customerId,
    );
  }

  /// Opens the stored-bill dialog over the real repositories.
  ///
  /// A single button rather than the whole shell: this file is about the refund action inside
  /// the dialog, and the two screens that open it are covered where they live.
  Future<void> openBill(
    WidgetTester tester,
    String orderId, {
    RefundRepository? refundRepository,
  }) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<OrderRepository>.value(value: orders),
          Provider<PaymentRepository>.value(value: payments),
          Provider<CustomerRepository>.value(value: customers),
          Provider<RefundRepository>.value(value: refundRepository ?? refunds),
          // Read by the reprint actions on the stored-bill dialog.
          Provider<PrintService>.value(
            value: TestPrinting.serviceOver(
              database,
              printer: UnconfiguredThermalPrinter(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: FilledButton(
                  onPressed: () =>
                      BillDetailView.show(context, orderId: orderId),
                  child: const Text('Open bill'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tap(tester, find.text('Open bill'));
  }

  /// Finds [matching] inside the stored-bill dialog rather than in a nested confirmation.
  Finder inBill(Finder matching) =>
      find.descendant(of: find.byType(BillDetailView), matching: matching);

  group('the refund action is offered where it should be', () {
    testWidgets('a settled bill shows the figures and offers a refund', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);

      expect(find.byType(BillDetailView), findsOneWidget);
      // The bill number, so the cashier can check it against the paper.
      expect(find.text('Bill 20260409-0001'), findsOneWidget);
      expect(inBill(find.text('Refund')), findsWidgets);
      // What came in, what has gone back, what is left.
      expect(inBill(find.text('Paid')), findsOneWidget);
      expect(inBill(find.text('Already refunded')), findsOneWidget);
      expect(inBill(find.text('Refundable now')), findsOneWidget);
      expect(inBill(find.text('₹210.00')), findsWidgets);
      expect(inBill(find.text('₹0.00')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a draft bill offers no refund and says why', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(
        () => settledBill(status: OrderStatus.draft),
      ) as String;

      await openBill(tester, id);

      expect(
        find.widgetWithText(FilledButton, 'Refund'),
        findsNothing,
        reason: 'a disabled button invites a tap that can never work',
      );
      expect(inBill(find.textContaining('still a draft')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cancelled bill offers no refund and says why', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(() async {
        final String created = await settledBill();
        await orders.cancelOrder(created);
        return created;
      }) as String;

      await openBill(tester, id);

      expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
      expect(inBill(find.textContaining('was cancelled')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bill with no tender offers no refund and says why', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(
        () => settledBill(paymentMethod: null),
      ) as String;

      await openBill(tester, id);

      expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
      // Matched on the refusal's own wording: the totals block separately says "No settled
      // payment recorded" beside "Paid by", and both are correct.
      expect(inBill(find.textContaining('nothing to refund')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an already refunded bill shows the reversal, not an action', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(() async {
        final String created = await settledBill();
        final RefundableBill bill = (await refunds.loadRefundable(created))
            .valueOrNull!;
        await refunds.refund(
          RefundRequest.forBill(bill, reason: 'Refunded yesterday'),
        );
        return created;
      }) as String;

      await openBill(tester, id);

      expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
      expect(inBill(find.text('Refunded on')), findsOneWidget);
      expect(inBill(find.text('Refunded by')), findsOneWidget);
      expect(inBill(find.text('Refunded yesterday')), findsOneWidget);
      expect(
        inBill(find.textContaining('already been refunded')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the confirmation', () {
    testWidgets('is required before any money moves', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));

      // The bill number and the exact amount, which are the two things to check against the
      // paper in front of whoever is about to hand money over.
      expect(find.text('Refund bill 20260409-0001?'), findsOneWidget);
      expect(find.textContaining('₹210.00 will be recorded'), findsOneWidget);
      // And what is deliberately not changed, said out loud.
      expect(find.textContaining('Stock is not put back'), findsOneWidget);
      expect(find.text('Keep the sale'), findsOneWidget);
      expect(find.text('Refund ₹210.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('declining it writes nothing', (WidgetTester tester) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Keep the sale'));

      final List<Refund> written = await tester.runAsync(
        () async => (await refunds.loadForOrder(id)).valueOrNull!,
      ) as List<Refund>;
      expect(written, isEmpty);
      // Back to the bill, with the action still available.
      expect(find.byType(BillDetailView), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Refund'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('a refund that succeeds', () {
    testWidgets('says so in place and shows what went back', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      // In place, in the dialog the cashier is already looking at. Not a snack bar: "did the
      // money go back" is not a question to answer transiently.
      expect(
        inBill(find.textContaining('₹210.00 refunded by Cash')),
        findsOneWidget,
      );
      expect(
        inBill(find.textContaining('original bill and payment are unchanged')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('writes exactly one reversal', (WidgetTester tester) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      final List<Refund> written = await tester.runAsync(
        () async => (await refunds.loadForOrder(id)).valueOrNull!,
      ) as List<Refund>;
      expect(written, hasLength(1));
      expect(written.single.amount.paise, 21000);
      expect(written.single.paymentMethod, PaymentMethod.cash);
      expect(written.single.status, PaymentStatus.completed);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the figures on screen are re-read from storage', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      // Already refunded ₹210.00, nothing refundable now.
      expect(inBill(find.text('Already refunded')), findsOneWidget);
      expect(inBill(find.text('₹0.00')), findsWidgets);
      // And the action is gone.
      expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the original sale is still on screen in full', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      expect(inBill(find.text('Test Pizza (Medium)')), findsOneWidget);
      expect(inBill(find.text('Grand total')), findsOneWidget);
      expect(inBill(find.text('Completed')), findsOneWidget);
      expect(inBill(find.text('Cash')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the stored payment is untouched', (WidgetTester tester) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      final bool intact = await tester.runAsync(() async {
        final tenders = (await payments.loadForOrder(id)).valueOrNull!;
        final order = (await orders.findOrder(id)).valueOrNull!;
        return tenders.length == 1 &&
            tenders.single.status == PaymentStatus.completed &&
            tenders.single.amount.paise == 21000 &&
            order.status == OrderStatus.completed &&
            order.totalAmount.paise == 21000;
      }) as bool;
      expect(intact, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the dialog still closes cleanly afterwards', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));
      await tap(tester, find.text('Close'));

      expect(find.byType(BillDetailView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('a refund that fails', () {
    testWidgets('shows the reason in place with no thrown exception', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(
        tester,
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      expect(
        inBill(find.text('The till is closed for the day.')),
        findsOneWidget,
      );
      // The whole point of this test.
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaves the bill readable behind the notice', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(
        tester,
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      // Nothing about the bill changed, so nothing about the bill is hidden.
      expect(inBill(find.text('Test Pizza (Medium)')), findsOneWidget);
      expect(inBill(find.text('Grand total')), findsOneWidget);
      expect(inBill(find.text('Refundable now')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('writes nothing', (WidgetTester tester) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(
        tester,
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      final List<Refund> written = await tester.runAsync(
        () async => (await refunds.loadForOrder(id)).valueOrNull!,
      ) as List<Refund>;
      expect(written, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the notice can be dismissed and the refund retried', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;
      final _FailOnceRefundRepository flaky = _FailOnceRefundRepository(
        refunds,
      );

      await openBill(tester, id, refundRepository: flaky);
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));
      expect(inBill(find.text('The database is busy.')), findsOneWidget);

      await tap(tester, find.byTooltip('Dismiss'));
      expect(inBill(find.text('The database is busy.')), findsNothing);

      // The action is still there, and the retry goes through.
      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      expect(
        inBill(find.textContaining('₹210.00 refunded by Cash')),
        findsOneWidget,
      );
      final List<Refund> written = await tester.runAsync(
        () async => (await refunds.loadForOrder(id)).valueOrNull!,
      ) as List<Refund>;
      // Retried, not repeated.
      expect(written, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bill refunded elsewhere is refused, not double refunded', (
      WidgetTester tester,
    ) async {
      final String id = await tester.runAsync(settledBill) as String;

      await openBill(tester, id);
      // Someone else refunds it while this dialog is open.
      await tester.runAsync(() async {
        final RefundableBill bill = (await refunds.loadRefundable(id))
            .valueOrNull!;
        await refunds.refund(RefundRequest.forBill(bill));
      });

      await tap(tester, find.widgetWithText(FilledButton, 'Refund'));
      await tap(tester, find.text('Refund ₹210.00'));

      expect(
        inBill(find.textContaining('already been refunded in full')),
        findsOneWidget,
      );
      final List<Refund> written = await tester.runAsync(
        () async => (await refunds.loadForOrder(id)).valueOrNull!,
      ) as List<Refund>;
      expect(written, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a bill whose figures cannot be read shows an error and a retry',
      (WidgetTester tester) async {
        final String id = await tester.runAsync(settledBill) as String;

        await openBill(
          tester,
          id,
          refundRepository: _FailingRefundRepository(),
        );

        expect(inBill(find.text('Storage is unavailable.')), findsOneWidget);
        expect(inBill(find.text('Try again')), findsOneWidget);
        // No refund action against figures that could not be read.
        expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('no sample data', () {
    testWidgets('an outlet with no bills has nothing to refund', (
      WidgetTester tester,
    ) async {
      await openBill(tester, 'ord-nothing');

      expect(
        inBill(find.textContaining('no longer on this terminal')),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Refund'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Refuses every refund with a validation failure, without touching the database.
class _RefusingRefundRepository implements RefundRepository {
  _RefusingRefundRepository(this._inner);

  final RefundRepository _inner;

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) =>
      _inner.loadRefundable(orderId);

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) =>
      _inner.loadForOrder(orderId);

  @override
  Future<Result<Refund>> refund(RefundRequest request) async =>
      const Err<Refund>(ValidationFailure('The till is closed for the day.'));
}

/// Fails the first refund and then behaves, so a retry can be driven on screen.
class _FailOnceRefundRepository implements RefundRepository {
  _FailOnceRefundRepository(this._inner);

  final RefundRepository _inner;
  bool _hasFailed = false;

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) =>
      _inner.loadRefundable(orderId);

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) =>
      _inner.loadForOrder(orderId);

  @override
  Future<Result<Refund>> refund(RefundRequest request) async {
    if (!_hasFailed) {
      _hasFailed = true;
      return const Err<Refund>(LocalStorageFailure('The database is busy.'));
    }
    return _inner.refund(request);
  }
}

/// Fails every read, so the bill's figures cannot be shown at all.
class _FailingRefundRepository implements RefundRepository {
  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) async =>
      const Err<RefundableBill?>(
        LocalStorageFailure('Storage is unavailable.'),
      );

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) async =>
      const Err<List<Refund>>(LocalStorageFailure('Storage is unavailable.'));

  @override
  Future<Result<Refund>> refund(RefundRequest request) async =>
      const Err<Refund>(LocalStorageFailure('Storage is unavailable.'));
}
