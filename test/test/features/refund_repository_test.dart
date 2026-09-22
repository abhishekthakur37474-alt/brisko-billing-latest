import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// Refunding a settled bill, against the real schema.
///
/// ## What these tests are really about
///
/// A refund is the one operation in this application that gives money away, so almost all
/// of its correctness is negative: what it refuses, and what it leaves alone. The groups
/// below are organised that way — first that it works, then every way it must not, then the
/// records it must not have touched while working.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteRefundRepository refunds;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteKotRepository kots;
  late SqliteCustomerRepository customers;

  /// A fixed day, so nothing here waits for a clock.
  final DateTime billedAt = DateTime(2026, 4, 9, 13, 30);
  final DateTime refundedAt = DateTime(2026, 4, 9, 15, 5);

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
    refunds = SqliteRefundRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    kots = SqliteKotRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// A settled takeaway bill of ₹210 with a cash tender and a kitchen slip.
  Future<String> settledBill({
    String orderNumber = '20260409-0001',
    String? customerId,
    String? kotNumber = 'K20260409-0001',
    OrderStatus status = OrderStatus.completed,
    PaymentMethod? paymentMethod = PaymentMethod.cash,
    PaymentStatus paymentStatus = PaymentStatus.completed,
    String? paymentAmount,
  }) {
    return seed.bill(
      orderNumber: orderNumber,
      at: billedAt,
      status: status,
      customerId: customerId,
      kotNumber: kotNumber,
      paymentMethod: paymentMethod,
      paymentStatus: paymentStatus,
      paymentAmount: paymentAmount,
    );
  }

  Future<RefundableBill> refundableOf(String orderId) async =>
      (await refunds.loadRefundable(orderId)).valueOrNull!;

  /// Refunds the whole of what [orderId] collected, as a screen would.
  Future<Result<Refund>> refundWholeBill(
    String orderId, {
    String? reason,
    DateTime? at,
  }) async {
    final RefundableBill bill = await refundableOf(orderId);
    return refunds.refund(
      RefundRequest.forBill(bill, reason: reason, at: at ?? refundedAt),
    );
  }

  group('refunding a completed bill', () {
    test('the money goes back and the reversal is recorded', () async {
      final String id = await settledBill();

      final Result<Refund> outcome = await refundWholeBill(
        id,
        reason: 'Wrong order sent out',
      );

      expect(outcome.isOk, isTrue);
      final Refund written = outcome.valueOrNull!;
      expect(written.orderId, id);
      expect(written.orderNumberSnapshot, '20260409-0001');
      expect(written.amount.paise, 21000);
      expect(written.paymentMethod, PaymentMethod.cash);
      expect(written.status, PaymentStatus.completed);
      expect(written.isSettled, isTrue);
      expect(written.reason, 'Wrong order sent out');
    });

    test('the amount refunded is what was collected, in paise', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      final List<Refund> stored = (await refunds.loadForOrder(id)).valueOrNull!;
      expect(stored, hasLength(1));
      // Integer paise, exactly the tender. Not the bill total by coincidence: the tender is
      // what the guard reads.
      expect(stored.single.amount.paise, 21000);
    });

    test('the reversal points at the tender it reversed', () async {
      final String id = await settledBill();
      final Payment tender = (await payments.loadForOrder(id))
          .valueOrNull!
          .single;

      final Refund written = (await refundWholeBill(id)).valueOrNull!;

      expect(written.paymentId, tender.id);
    });

    test('a refund with no reason given is still recorded', () async {
      final String id = await settledBill();

      final Refund written = (await refundWholeBill(id)).valueOrNull!;

      // Null rather than an empty string, so "no reason given" is one value everywhere.
      expect(written.reason, isNull);
    });

    test('a blank reason is stored as no reason at all', () async {
      final String id = await settledBill();

      final Refund written = (await refundWholeBill(
        id,
        reason: '   ',
      )).valueOrNull!;

      expect(written.reason, isNull);
    });

    test('the bill reports nothing left to refund afterwards', () async {
      final String id = await settledBill();
      final RefundableBill before = await refundableOf(id);
      expect(before.refundableAmount.paise, 21000);
      expect(before.canRefund, isTrue);

      await refundWholeBill(id);

      final RefundableBill after = await refundableOf(id);
      expect(after.paidAmount.paise, 21000);
      expect(after.refundedAmount.paise, 21000);
      expect(after.refundableAmount.paise, 0);
      expect(after.isFullyRefunded, isTrue);
      expect(after.canRefund, isFalse);
      expect(after.refusalReason, contains('already been refunded in full'));
    });

    test('a refunded bill by UPI goes back by UPI', () async {
      final String id = await settledBill(paymentMethod: PaymentMethod.upi);

      final Refund written = (await refundWholeBill(id)).valueOrNull!;

      // Back the way it came in. No refund-specific tender type exists.
      expect(written.paymentMethod, PaymentMethod.upi);
    });
  });

  group('what cannot be refunded', () {
    test('a bill that is not on this terminal', () async {
      final Result<Refund> missing = await refunds.refund(
        RefundRequest(
          id: 'ref-nothing',
          orderId: 'ord-nothing',
          amount: const Money.fromPaise(21000),
          requestedAt: refundedAt,
        ),
      );

      expect(missing.isErr, isTrue);
      expect(missing.failureOrNull, isA<ValidationFailure>());
      expect(
        missing.failureOrNull!.message,
        contains('no longer on this terminal'),
      );
    });

    test('a draft bill', () async {
      final String id = await settledBill(status: OrderStatus.draft);

      final Result<Refund> refused = await refundWholeBill(id);

      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull, isA<ValidationFailure>());
      expect(refused.failureOrNull!.message, contains('still a draft'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('a cancelled bill', () async {
      final String id = await settledBill();
      await orders.cancelOrder(id);

      final Result<Refund> refused = await refundWholeBill(id);

      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull, isA<ValidationFailure>());
      expect(refused.failureOrNull!.message, contains('was cancelled'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('a bill that has been confirmed but not settled', () async {
      final String id = await settledBill(status: OrderStatus.confirmed);

      final Result<Refund> refused = await refundWholeBill(id);

      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull!.message, contains('not been settled'));
    });

    test('a bill still being prepared, or ready but unpaid', () async {
      final String preparing = await settledBill(
        orderNumber: '20260409-0002',
        kotNumber: 'K20260409-0002',
        status: OrderStatus.preparing,
      );
      final String ready = await settledBill(
        orderNumber: '20260409-0003',
        kotNumber: 'K20260409-0003',
        status: OrderStatus.ready,
      );

      expect((await refundWholeBill(preparing)).isErr, isTrue);
      expect((await refundWholeBill(ready)).isErr, isTrue);
    });

    test('a bill with no tender recorded at all', () async {
      final String id = await settledBill(paymentMethod: null);

      final RefundableBill bill = await refundableOf(id);
      expect(bill.hasSettledPayment, isFalse);
      expect(bill.canRefund, isFalse);
      expect(bill.refusalReason, contains('No settled payment'));

      // And the repository refuses it too, not only the read model.
      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-untendered',
          orderId: id,
          amount: const Money.fromPaise(21000),
          requestedAt: refundedAt,
        ),
      );
      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull!.message, contains('No settled payment'));
    });

    test('a bill whose tender never landed', () async {
      // A UPI attempt recorded but not confirmed. The money is not in, so it cannot go out.
      final String id = await settledBill(
        paymentMethod: PaymentMethod.upi,
        paymentStatus: PaymentStatus.pending,
      );

      final RefundableBill bill = await refundableOf(id);
      expect(bill.paidAmount.paise, 0);
      expect(bill.canRefund, isFalse);

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-pending',
          orderId: id,
          amount: const Money.fromPaise(21000),
          requestedAt: refundedAt,
        ),
      );
      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull!.message, contains('No settled payment'));
    });

    test('a second, different refund on an already refunded bill', () async {
      final String id = await settledBill();
      expect((await refundWholeBill(id)).isOk, isTrue);

      // A fresh request: a new intent, not a retry of the first.
      final Result<Refund> again = await refunds.refund(
        RefundRequest(
          id: 'ref-second-attempt',
          orderId: id,
          amount: const Money.fromPaise(21000),
          requestedAt: refundedAt,
        ),
      );

      expect(again.isErr, isTrue);
      expect(again.failureOrNull, isA<ValidationFailure>());
      expect(
        again.failureOrNull!.message,
        contains('already been refunded in full'),
      );
      // And exactly one reversal exists.
      expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
    });

    test('a refund of nothing', () async {
      final String id = await settledBill();

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-zero',
          orderId: id,
          amount: Money.zero,
          requestedAt: refundedAt,
        ),
      );

      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull!.message, contains('more than nothing'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('a bill settled with more than one tender', () async {
      final String id = await settledBill();
      // Split payment is not something the application can currently produce, so it is
      // arranged directly. Refusing it is the point: sending the whole amount back by one of
      // two methods is a decision about someone else's money.
      expect(
        (await payments.record(
          Fixtures.payment(
            orderId: id,
            method: PaymentMethod.card,
            amount: '10.00',
            createdAt: billedAt,
          ),
        )).isOk,
        isTrue,
      );

      final RefundableBill bill = await refundableOf(id);
      expect(bill.settledTenderCount, 2);
      expect(bill.canRefund, isFalse);
      expect(bill.refusalReason, contains('more than one payment'));

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-split',
          orderId: id,
          amount: const Money.fromPaise(22000),
          requestedAt: refundedAt,
        ),
      );
      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull!.message, contains('more than one payment'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });
  });

  group('the amount is validated against what was collected', () {
    test('more than was collected is refused', () async {
      final String id = await settledBill();

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-too-much',
          orderId: id,
          // One paisa more than the ₹210 tender.
          amount: const Money.fromPaise(21001),
          requestedAt: refundedAt,
        ),
      );

      expect(refused.isErr, isTrue);
      expect(refused.failureOrNull, isA<ValidationFailure>());
      expect(refused.failureOrNull!.message, contains('cannot be refunded'));
      expect(refused.failureOrNull!.message, contains('210.00'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('far more than was collected is refused', () async {
      final String id = await settledBill();

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-way-too-much',
          orderId: id,
          amount: const Money.fromPaise(9999900),
          requestedAt: refundedAt,
        ),
      );

      expect(refused.isErr, isTrue);
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('less than the remainder is refused in this step', () async {
      final String id = await settledBill();

      final Result<Refund> refused = await refunds.refund(
        RefundRequest(
          id: 'ref-partial',
          orderId: id,
          amount: const Money.fromPaise(10000),
          requestedAt: refundedAt,
        ),
      );

      expect(refused.isErr, isTrue);
      // Refused rather than quietly rounded up to the full amount, which would move money
      // the cashier did not ask to move.
      expect(refused.failureOrNull!.message, contains('whole bill'));
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('the collected amount governs, not the bill total', () async {
      // A bill of ₹210 against which only ₹200 was actually taken.
      final String id = await settledBill(paymentAmount: '200.00');

      final RefundableBill bill = await refundableOf(id);
      expect(bill.billTotal.paise, 21000);
      expect(bill.paidAmount.paise, 20000);
      expect(bill.refundableAmount.paise, 20000);
      expect(bill.isUnderpaid, isTrue);

      final Refund written = (await refundWholeBill(id)).valueOrNull!;
      expect(written.amount.paise, 20000);

      // And the bill total was never a ceiling anyone could refund up to.
      final Result<Refund> tooMuch = await refunds.refund(
        RefundRequest(
          id: 'ref-up-to-total',
          orderId: id,
          amount: const Money.fromPaise(21000),
          requestedAt: refundedAt,
        ),
      );
      expect(tooMuch.isErr, isTrue);
    });
  });

  group('retrying and racing', () {
    test('the same request repeated refunds the money once', () async {
      final String id = await settledBill();
      final RefundableBill bill = await refundableOf(id);
      final RefundRequest request = RefundRequest.forBill(bill, at: refundedAt);

      final Result<Refund> first = await refunds.refund(request);
      final Result<Refund> second = await refunds.refund(request);

      expect(first.isOk, isTrue);
      // The retry succeeds and reports the reversal that already exists, rather than
      // refusing. That is what makes a retry after a lost acknowledgement safe.
      expect(second.isOk, isTrue);
      expect(second.valueOrNull!.id, first.valueOrNull!.id);
      expect(second.valueOrNull!.amount.paise, 21000);

      // One row, one reversal, one amount.
      final List<Refund> stored = (await refunds.loadForOrder(id)).valueOrNull!;
      expect(stored, hasLength(1));
      expect(stored.single.amount.paise, 21000);
      expect((await refundableOf(id)).refundedAmount.paise, 21000);
    });

    test('the same request repeated many times still refunds once', () async {
      final String id = await settledBill();
      final RefundRequest request = RefundRequest.forBill(
        await refundableOf(id),
        at: refundedAt,
      );

      for (int attempt = 0; attempt < 5; attempt++) {
        expect((await refunds.refund(request)).isOk, isTrue);
      }

      expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
      expect((await refundableOf(id)).refundedAmount.paise, 21000);
    });

    test('two simultaneous refunds of one bill pay out once', () async {
      final String id = await settledBill();
      final RefundableBill bill = await refundableOf(id);

      // Two distinct intents, fired together. Transactions are serialised on the single
      // connection, so the second reads the first's committed row and is refused.
      final List<Result<Refund>> outcomes = await Future.wait(
        <Future<Result<Refund>>>[
          refunds.refund(RefundRequest.forBill(bill, at: refundedAt)),
          refunds.refund(RefundRequest.forBill(bill, at: refundedAt)),
        ],
      );

      expect(outcomes.where((Result<Refund> r) => r.isOk), hasLength(1));
      expect(outcomes.where((Result<Refund> r) => r.isErr), hasLength(1));
      expect(
        outcomes.firstWhere((Result<Refund> r) => r.isErr).failureOrNull,
        isA<ValidationFailure>(),
      );

      final List<Refund> stored = (await refunds.loadForOrder(id)).valueOrNull!;
      expect(stored, hasLength(1));
      expect(stored.single.amount.paise, 21000);
      expect((await refundableOf(id)).refundedAmount.paise, 21000);
    });

    test('five simultaneous refunds of one bill pay out once', () async {
      final String id = await settledBill();
      final RefundableBill bill = await refundableOf(id);

      final List<Result<Refund>> outcomes = await Future.wait(
        List<Future<Result<Refund>>>.generate(
          5,
          (int _) =>
              refunds.refund(RefundRequest.forBill(bill, at: refundedAt)),
        ),
      );

      expect(outcomes.where((Result<Refund> r) => r.isOk), hasLength(1));
      expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
    });

    test(
      'the database refuses a second reversal even without the guard',
      () async {
        // The backstop underneath the in-transaction check: the unique index. Written directly,
        // bypassing the repository entirely, so this holds even if the guard were removed.
        final String id = await settledBill();
        await refundWholeBill(id);

        await expectLater(
          database.database.insert(SqliteTables.refunds, <String, Object?>{
            'id': 'ref-bypassing-the-guard',
            'createdAt': 0,
            'updatedAt': 0,
            'isDeleted': 0,
            'syncState': 'pending',
            'orderId': id,
            'paymentId': (await payments.loadForOrder(id))
                .valueOrNull!
                .single
                .id,
            'orderNumberSnapshot': '20260409-0001',
            'paymentMethod': 'cash',
            'amountPaise': 21000,
            'status': 'completed',
          }),
          throwsA(isA<Object>()),
        );

        expect((await refunds.loadForOrder(id)).valueOrNull, hasLength(1));
      },
    );

    test('two different bills can both be refunded', () async {
      final String first = await settledBill();
      final String second = await settledBill(
        orderNumber: '20260409-0007',
        kotNumber: 'K20260409-0007',
      );

      expect((await refundWholeBill(first)).isOk, isTrue);
      expect((await refundWholeBill(second)).isOk, isTrue);

      expect((await refunds.loadForOrder(first)).valueOrNull, hasLength(1));
      expect((await refunds.loadForOrder(second)).valueOrNull, hasLength(1));
    });
  });

  group('the original sale survives untouched', () {
    test('the completed payment is not modified or deleted', () async {
      final String id = await settledBill();
      final Payment before = (await payments.loadForOrder(id))
          .valueOrNull!
          .single;

      await refundWholeBill(id);

      final List<Payment> after = (await payments.loadForOrder(id))
          .valueOrNull!;
      // Still exactly one tender, still saying the money arrived.
      expect(after, hasLength(1));
      final Payment tender = after.single;
      expect(tender.id, before.id);
      expect(tender.amount.paise, before.amount.paise);
      expect(tender.paymentMethod, before.paymentMethod);
      expect(tender.reference, before.reference);
      expect(tender.createdAt, before.createdAt);
      expect(tender.updatedAt, before.updatedAt);
      expect(tender.isDeleted, isFalse);
      // Not flipped to `refunded`: that would erase the arrival to describe the departure.
      expect(tender.status, PaymentStatus.completed);
    });

    test('the settled tender total is unchanged', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      // The money did arrive, and this figure is what says so.
      expect(
        (await payments.settledTotalForOrder(id)).valueOrNull!.paise,
        21000,
      );
    });

    test('the order status and its amounts are unchanged', () async {
      final String id = await settledBill();
      final Order before = (await orders.findOrder(id)).valueOrNull!;

      await refundWholeBill(id);

      final Order after = (await orders.findOrder(id)).valueOrNull!;
      expect(after.status, OrderStatus.completed);
      expect(after.orderNumber, before.orderNumber);
      expect(after.subtotal.paise, before.subtotal.paise);
      expect(after.discountAmount.paise, before.discountAmount.paise);
      expect(after.taxAmount.paise, before.taxAmount.paise);
      expect(after.totalAmount.paise, before.totalAmount.paise);
      expect(after.createdAt, before.createdAt);
      expect(after.updatedAt, before.updatedAt);
      expect(after.isDeleted, isFalse);
    });

    test('the stored lines and options are unchanged', () async {
      final String id = await seed.bill(
        orderNumber: '20260409-0011',
        at: billedAt,
        kotNumber: 'K20260409-0011',
        lines: const <BillLineSpec>[
          BillLineSpec(optionName: 'Extra Cheese', optionPrice: '70.00'),
        ],
      );
      final List<dynamic> before = (await orders.loadBillLines(id))
          .valueOrNull!;

      await refundWholeBill(id);

      final List<dynamic> after = (await orders.loadBillLines(id)).valueOrNull!;
      expect(after, hasLength(before.length));
      expect(after.single.displayName, 'Test Pizza (Medium)');
      expect(after.single.quantity, 2);
      expect(after.single.unitPrice.paise, 10000);
      expect(after.single.lineTotal.paise, 20000);
      expect(after.single.options, hasLength(1));
      expect(after.single.options.single.optionNameSnapshot, 'Extra Cheese');
    });

    test('the kitchen slip is not rewritten', () async {
      final String id = await settledBill();
      final dynamic before = (await kots.loadForOrder(id)).valueOrNull!.single;

      await refundWholeBill(id);

      final dynamic after = (await kots.loadForOrder(id)).valueOrNull!.single;
      expect(after.id, before.id);
      expect(after.kotNumber, 'K20260409-0001');
      // Whatever it was, it still is. A refund is not kitchen work.
      expect(after.status, before.status);
      expect(after.status, isNot(KotStatus.cancelled));
    });

    test('the customer association is kept', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await refundWholeBill(id);

      expect((await orders.findOrder(id)).valueOrNull!.customerId, customerId);
      expect(
        (await customers.findByPhone('9000000001')).valueOrNull!.id,
        customerId,
      );
    });

    test('the bill is still readable in full', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      final Order? order = (await orders.findOrder(id)).valueOrNull;
      expect(order, isNotNull);
      expect(order!.orderNumber, '20260409-0001');
      expect((await orders.loadBillLines(id)).valueOrNull, hasLength(1));
      expect((await payments.loadForOrder(id)).valueOrNull, hasLength(1));
    });
  });

  group('reading what a bill can refund', () {
    test(
      'a bill that is not stored reads as absent, not as a failure',
      () async {
        final Result<RefundableBill?> found = await refunds.loadRefundable(
          'ord-nothing',
        );

        expect(found.isOk, isTrue);
        expect(found.valueOrNull, isNull);
      },
    );

    test('an unrefunded bill reports the whole tender as refundable', () async {
      final String id = await settledBill();

      final RefundableBill bill = await refundableOf(id);

      expect(bill.orderNumber, '20260409-0001');
      expect(bill.orderStatus, OrderStatus.completed);
      expect(bill.billTotal.paise, 21000);
      expect(bill.paidAmount.paise, 21000);
      expect(bill.refundedAmount.paise, 0);
      expect(bill.refundableAmount.paise, 21000);
      expect(bill.settledTenderCount, 1);
      expect(bill.paymentMethod, PaymentMethod.cash);
      expect(bill.hasRefund, isFalse);
      expect(bill.existingRefund, isNull);
      expect(bill.isFullyRefunded, isFalse);
      expect(bill.isUnderpaid, isFalse);
      expect(bill.canRefund, isTrue);
      expect(bill.refusalReason, isNull);
    });

    test('a refunded bill carries the reversal that was written', () async {
      final String id = await settledBill();
      final Refund written = (await refundWholeBill(
        id,
        reason: 'Customer complaint',
      )).valueOrNull!;

      final RefundableBill bill = await refundableOf(id);

      expect(bill.hasRefund, isTrue);
      expect(bill.existingRefund!.id, written.id);
      expect(bill.existingRefund!.reason, 'Customer complaint');
      expect(bill.existingRefund!.createdAt, refundedAt.toUtc());
    });

    test('refunds for a bill with none is an empty list', () async {
      final String id = await settledBill();

      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });
  });
}
