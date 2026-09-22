import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/presentation/controllers/bill_detail_controller.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/payments/domain/repositories/refund_repository.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// The controller behind the stored-bill screen, refunding.
///
/// ## What is being held here
///
/// A refund that fails must leave the bill on screen intact, because the document is still
/// perfectly readable and the cashier needs it while being told why the money did not move.
/// And a refund that succeeds must publish figures read back from storage rather than figures
/// this controller assumed, so the screen can never disagree with the database.
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

  Future<String> settledBill({
    String orderNumber = '20260409-0001',
    OrderStatus status = OrderStatus.completed,
    String? customerId,
    PaymentMethod? paymentMethod = PaymentMethod.cash,
  }) {
    return seed.bill(
      orderNumber: orderNumber,
      at: billedAt,
      status: status,
      customerId: customerId,
      kotNumber: 'K$orderNumber',
      paymentMethod: paymentMethod,
    );
  }

  Future<BillDetailController> openBill(
    String orderId, {
    RefundRepository? refundRepository,
  }) async {
    final BillDetailController controller = BillDetailController(
      orderId: orderId,
      orderRepository: orders,
      paymentRepository: payments,
      customerRepository: customers,
      refundRepository: refundRepository ?? refunds,
      printService: TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    return controller;
  }

  group('what the screen shows before a refund', () {
    test('the three figures a refund decision needs', () async {
      final String id = await settledBill();

      final BillDetailController controller = await openBill(id);

      expect(controller.hasError, isFalse);
      expect(controller.orderNumber, '20260409-0001');
      expect(controller.paidAmount.paise, 21000);
      expect(controller.refundedAmount.paise, 0);
      expect(controller.refundableAmount.paise, 21000);
      expect(controller.canRefund, isTrue);
      expect(controller.refundRefusal, isNull);
      expect(controller.hasRefunded, isFalse);
      expect(controller.hasRefundError, isFalse);
      expect(controller.isRefunding, isFalse);
    });

    test('a draft bill offers no refund and says why', () async {
      final String id = await settledBill(status: OrderStatus.draft);

      final BillDetailController controller = await openBill(id);

      expect(controller.canRefund, isFalse);
      expect(controller.refundRefusal, contains('still a draft'));
    });

    test('a cancelled bill offers no refund and says why', () async {
      final String id = await settledBill();
      await orders.cancelOrder(id);

      final BillDetailController controller = await openBill(id);

      expect(controller.canRefund, isFalse);
      expect(controller.refundRefusal, contains('was cancelled'));
    });

    test('a bill with no tender offers no refund and says why', () async {
      final String id = await settledBill(paymentMethod: null);

      final BillDetailController controller = await openBill(id);

      expect(controller.paidAmount.paise, 0);
      expect(controller.canRefund, isFalse);
      expect(controller.refundRefusal, contains('No settled payment'));
    });

    test('an already refunded bill shows the reversal and offers no more', () async {
      final String id = await settledBill();
      final RefundableBill bill = (await refunds.loadRefundable(id))
          .valueOrNull!;
      await refunds.refund(
        RefundRequest.forBill(bill, reason: 'Refunded earlier'),
      );

      final BillDetailController controller = await openBill(id);

      expect(controller.refundedAmount.paise, 21000);
      expect(controller.refundableAmount.paise, 0);
      expect(controller.canRefund, isFalse);
      expect(controller.refundRefusal, contains('already been refunded'));
      // The existing reversal is available so the screen can say when and why.
      expect(controller.refundable!.existingRefund, isNotNull);
      expect(controller.refundable!.existingRefund!.reason, 'Refunded earlier');
      // But not as something this screen did.
      expect(controller.hasRefunded, isFalse);
      expect(controller.justRefunded, isNull);
    });

    test(
      'a bill that is not on the terminal is missing, not an error',
      () async {
        final BillDetailController controller = await openBill('ord-nothing');

        expect(controller.isMissing, isTrue);
        expect(controller.hasError, isFalse);
        expect(controller.refundable, isNull);
        expect(controller.canRefund, isFalse);
      },
    );
  });

  group('a successful refund', () {
    test('reports success and records what went back', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);

      final bool refunded = await controller.refund(reason: 'Wrong order');

      expect(refunded, isTrue);
      expect(controller.hasRefunded, isTrue);
      expect(controller.justRefunded!.amount.paise, 21000);
      expect(controller.justRefunded!.paymentMethod, PaymentMethod.cash);
      expect(controller.justRefunded!.reason, 'Wrong order');
      expect(controller.hasRefundError, isFalse);
      expect(controller.isRefunding, isFalse);
    });

    test('the figures are re-read from storage afterwards', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);

      await controller.refund();

      // Read back, not adjusted in memory, so the screen cannot disagree with the database.
      expect(controller.refundedAmount.paise, 21000);
      expect(controller.refundableAmount.paise, 0);
      expect(controller.refundable!.isFullyRefunded, isTrue);
      expect(controller.refundable!.existingRefund, isNotNull);
    });

    test('the action is not offered again from the same screen', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);

      await controller.refund();

      expect(controller.canRefund, isFalse);
      // Not a refusal to explain: the success notice is what the screen shows instead.
      expect(controller.refundRefusal, isNull);
    });

    test(
      'a second call after success writes nothing and reports false',
      () async {
        final String id = await settledBill();
        final BillDetailController controller = await openBill(id);
        await controller.refund();

        final bool again = await controller.refund();

        expect(again, isFalse);
        expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
      },
    );

    test('the bill on screen is unchanged by its own refund', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);

      await controller.refund();

      expect(controller.order!.status, OrderStatus.completed);
      expect(controller.order!.totalAmount.paise, 21000);
      expect(controller.lines, hasLength(1));
      expect(controller.payments, hasLength(1));
      expect(controller.payments.single.status, PaymentStatus.completed);
      expect(controller.payments.single.amount.paise, 21000);
      expect(controller.paymentMethod, PaymentMethod.cash);
      expect(controller.isConsistent, isTrue);
    });

    test('the customer is still on the bill afterwards', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);
      final BillDetailController controller = await openBill(id);

      await controller.refund();

      expect(controller.customer, isNotNull);
      expect(controller.customerPhone, '9000000001');
    });

    test('it notifies its listeners', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);
      int notifications = 0;
      controller.addListener(() => notifications++);

      await controller.refund();

      // At least the in-flight state and the outcome.
      expect(notifications, greaterThanOrEqualTo(2));
    });
  });

  group('a refused refund', () {
    test('reports the reason and leaves the bill on screen', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);
      // Someone else refunds it between the screen opening and the button being tapped.
      await refunds.refund(
        RefundRequest.forBill((await refunds.loadRefundable(id)).valueOrNull!),
      );

      final bool refunded = await controller.refund();

      expect(refunded, isFalse);
      expect(controller.hasRefundError, isTrue);
      expect(controller.refundError, contains('already been refunded in full'));
      expect(controller.hasRefunded, isFalse);
      // The document is still there. Blanking it would be the wrong response to a refused
      // refund: nothing about the bill changed.
      expect(controller.hasError, isFalse);
      expect(controller.order, isNotNull);
      expect(controller.lines, hasLength(1));
      expect(controller.payments, hasLength(1));
      expect(controller.isRefunding, isFalse);
    });

    test('the refund error is separate from a read error', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );

      await controller.refund();

      expect(controller.hasRefundError, isTrue);
      // `errorMessage` is what blanks the bill. A refused refund must not set it.
      expect(controller.errorMessage, isNull);
      expect(controller.hasError, isFalse);
    });

    test('the notice can be dismissed without touching the figures', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );
      await controller.refund();
      expect(controller.hasRefundError, isTrue);

      controller.dismissRefundError();

      expect(controller.hasRefundError, isFalse);
      expect(controller.refundError, isNull);
      expect(controller.refundableAmount.paise, 21000);
      expect(controller.canRefund, isTrue);
    });

    test('dismissing when there is nothing to dismiss does nothing', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(id);
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.dismissRefundError();

      expect(notifications, 0);
    });

    test('nothing was written', () async {
      final String id = await settledBill();
      final BillDetailController controller = await openBill(
        id,
        refundRepository: _RefusingRefundRepository(refunds),
      );

      await controller.refund();

      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
      expect(
        (await payments.loadForOrder(id)).valueOrNull!.single.status,
        PaymentStatus.completed,
      );
      expect(
        (await orders.findOrder(id)).valueOrNull!.status,
        OrderStatus.completed,
      );
    });

    test(
      'a retry reuses the same request rather than starting a second',
      () async {
        final String id = await settledBill();
        final _CountingRefundRepository counting = _CountingRefundRepository(
          refunds,
        );
        final BillDetailController controller = await openBill(
          id,
          refundRepository: counting,
        );

        counting.failNext = true;
        expect(await controller.refund(), isFalse);
        counting.failNext = false;
        expect(await controller.refund(), isTrue);

        // Both attempts carried the same id, which is what makes the second a retry rather than
        // a second refund.
        expect(counting.requestIds, hasLength(2));
        expect(counting.requestIds.first, counting.requestIds.last);
        expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
      },
    );

    test('a refund on a bill that never loaded is refused locally', () async {
      final BillDetailController controller = await openBill('ord-nothing');

      final bool refunded = await controller.refund();

      expect(refunded, isFalse);
      expect(controller.hasRefundError, isTrue);
      expect(controller.refundError, contains('not finished loading'));
    });
  });

  group('a read that fails', () {
    test(
      'a failed refundable read blanks the bill rather than half showing it',
      () async {
        final String id = await settledBill();

        final BillDetailController controller = await openBill(
          id,
          refundRepository: _FailingRefundRepository(),
        );

        // A bill shown with a Refund button whose amounts could not be read is a bill somebody
        // could refund the wrong amount of.
        expect(controller.hasError, isTrue);
        expect(controller.errorMessage, contains('Storage is unavailable'));
        expect(controller.order, isNull);
        expect(controller.refundable, isNull);
        expect(controller.canRefund, isFalse);
      },
    );

    test('it can be retried once the fault clears', () async {
      final String id = await settledBill();
      final _FlakyOnceRefundRepository flaky = _FlakyOnceRefundRepository(
        refunds,
      );
      final BillDetailController controller = await openBill(
        id,
        refundRepository: flaky,
      );
      expect(controller.hasError, isTrue);

      await controller.retry();

      expect(controller.hasError, isFalse);
      expect(controller.refundableAmount.paise, 21000);
      expect(controller.canRefund, isTrue);
    });

    test(
      'a refund that succeeds survives a failed refresh afterwards',
      () async {
        final String id = await settledBill();
        final _FailAfterRefundRepository awkward = _FailAfterRefundRepository(
          refunds,
        );
        final BillDetailController controller = await openBill(
          id,
          refundRepository: awkward,
        );

        final bool refunded = await controller.refund();

        // The money went back. A read that fails afterwards must not be reported as a refund
        // that failed: that is the one lie this screen could tell that costs money twice.
        expect(refunded, isTrue);
        expect(controller.hasRefunded, isTrue);
        expect(controller.hasRefundError, isFalse);
        expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
      },
    );
  });

  group('disposal', () {
    test('a refund finishing after disposal does not throw', () async {
      final String id = await settledBill();
      final BillDetailController controller = BillDetailController(
        orderId: id,
        orderRepository: orders,
        paymentRepository: payments,
        customerRepository: customers,
        refundRepository: refunds,
        printService: TestPrinting.serviceOver(
          database,
          printer: UnconfiguredThermalPrinter(),
        ),
      );
      await controller.load();

      final Future<bool> inFlight = controller.refund();
      controller.dispose();

      // The write must still complete; only the notification is dropped.
      await expectLater(inFlight, completes);
      expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
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

/// Fails every read, so the bill cannot be shown at all.
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

/// Fails the first read and then behaves, so a retry can be shown to work.
class _FlakyOnceRefundRepository implements RefundRepository {
  _FlakyOnceRefundRepository(this._inner);

  final RefundRepository _inner;
  bool _hasFailed = false;

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) async {
    if (!_hasFailed) {
      _hasFailed = true;
      return const Err<RefundableBill?>(
        LocalStorageFailure('Storage is unavailable.'),
      );
    }
    return _inner.loadRefundable(orderId);
  }

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) =>
      _inner.loadForOrder(orderId);

  @override
  Future<Result<Refund>> refund(RefundRequest request) =>
      _inner.refund(request);
}

/// Writes the refund, then fails the read that follows it.
class _FailAfterRefundRepository implements RefundRepository {
  _FailAfterRefundRepository(this._inner);

  final RefundRepository _inner;
  bool _hasRefunded = false;

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) async {
    if (_hasRefunded) {
      return const Err<RefundableBill?>(
        LocalStorageFailure('Storage is unavailable.'),
      );
    }
    return _inner.loadRefundable(orderId);
  }

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) =>
      _inner.loadForOrder(orderId);

  @override
  Future<Result<Refund>> refund(RefundRequest request) async {
    final Result<Refund> outcome = await _inner.refund(request);
    _hasRefunded = true;
    return outcome;
  }
}

/// Records the request ids it is asked to write, and can be told to fail once.
class _CountingRefundRepository implements RefundRepository {
  _CountingRefundRepository(this._inner);

  final RefundRepository _inner;

  /// Ids of every request handed to [refund], in order.
  final List<String> requestIds = <String>[];

  bool failNext = false;

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) =>
      _inner.loadRefundable(orderId);

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) =>
      _inner.loadForOrder(orderId);

  @override
  Future<Result<Refund>> refund(RefundRequest request) async {
    requestIds.add(request.id);
    if (failNext) {
      return const Err<Refund>(LocalStorageFailure('The database is busy.'));
    }
    return _inner.refund(request);
  }
}
