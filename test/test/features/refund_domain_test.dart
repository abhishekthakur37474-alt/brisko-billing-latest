import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_cancellation.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_policy.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules a refund follows, and the decisions it deliberately does not act on.
///
/// A refund's safety is mostly a list of things it leaves alone, and an omission in a
/// repository method is invisible — it reads as code nobody wrote rather than as a decision.
/// So every omission is a named constant on [RefundPolicy] and every one of them is asserted
/// here. This is the same convention `order_cancellation_test.dart` holds
/// `OrderCancellation` to.
void main() {
  /// A settled ₹210 cash bill as the read model would describe it.
  RefundableBill bill({
    OrderStatus status = OrderStatus.completed,
    int paidPaise = 21000,
    int refundedPaise = 0,
    int totalPaise = 21000,
    int tenders = 1,
    PaymentMethod? method = PaymentMethod.cash,
    Refund? existingRefund,
  }) {
    return RefundableBill(
      orderId: 'ord-1',
      orderNumber: '20260409-0001',
      orderStatus: status,
      billTotal: Money.fromPaise(totalPaise),
      paidAmount: Money.fromPaise(paidPaise),
      refundedAmount: Money.fromPaise(refundedPaise),
      settledTenderCount: tenders,
      paymentMethod: method,
      existingRefund: existingRefund,
    );
  }

  Refund reversal({int amountPaise = 21000, String? reason}) => Refund(
    id: 'ref-1',
    orderId: 'ord-1',
    paymentId: 'pay-1',
    orderNumberSnapshot: '20260409-0001',
    paymentMethod: PaymentMethod.cash,
    amount: Money.fromPaise(amountPaise),
    reason: reason,
    status: PaymentStatus.completed,
    createdAt: DateTime.utc(2026, 4, 9, 15),
    updatedAt: DateTime.utc(2026, 4, 9, 15),
  );

  group('which bills a refund is legal from', () {
    test('only a completed bill can be refunded', () {
      expect(RefundPolicy.refundableOrderStatus, OrderStatus.completed);
      expect(RefundPolicy.canRefund(OrderStatus.completed), isTrue);

      for (final OrderStatus status in OrderStatus.values) {
        if (status == OrderStatus.completed) {
          continue;
        }
        expect(
          RefundPolicy.canRefund(status),
          isFalse,
          reason: '$status is not a state in which money has been taken.',
        );
      }
    });

    test('every refusal explains what the bill is, not just that it is no', () {
      // The cashier's next action differs by case: a draft has to be settled, a cancelled
      // bill never took the money at all.
      expect(
        RefundPolicy.refusalReason(OrderStatus.draft),
        contains('still a draft'),
      );
      expect(
        RefundPolicy.refusalReason(OrderStatus.cancelled),
        contains('was cancelled'),
      );
      expect(
        RefundPolicy.refusalReason(OrderStatus.confirmed),
        contains('not been settled'),
      );
      expect(
        RefundPolicy.refusalReason(OrderStatus.preparing),
        contains('not been settled'),
      );
      expect(
        RefundPolicy.refusalReason(OrderStatus.ready),
        contains('not been settled'),
      );
      expect(RefundPolicy.refusalReason(OrderStatus.completed), isNull);
    });

    test('the rule and its wording cannot disagree', () {
      for (final OrderStatus status in OrderStatus.values) {
        expect(
          RefundPolicy.refusalReason(status) == null,
          RefundPolicy.canRefund(status),
          reason:
              '$status must either be refundable with no reason, or refused '
              'with one.',
        );
      }
    });

    test(
      'refunding is legal from one status where cancelling is legal from five',
      () {
        // The two are deliberately opposite shapes. A cancellation's reason arrives from
        // outside the workflow so it is legal almost everywhere; a refund is a movement of
        // money so it is legal only where money has moved.
        final int refundable = OrderStatus.values
            .where(RefundPolicy.canRefund)
            .length;
        final int cancellable = OrderStatus.values
            .where(OrderCancellation.canCancel)
            .length;

        expect(refundable, 1);
        expect(cancellable, OrderStatus.values.length - 1);
      },
    );
  });

  group('what a refund deliberately does not do', () {
    test('it does not rewrite the tender it reverses', () {
      // The row saying money arrived must keep saying so, or the shift it arrived on stops
      // reconciling.
      expect(RefundPolicy.reversesOriginalPayment, isFalse);
    });

    test('it does not move the order status', () {
      expect(RefundPolicy.changesOrderStatus, isFalse);
      // And no refunded status was invented to move it to. A single status cannot say
      // "counts towards gross but not towards net".
      expect(OrderStatus.values.map((OrderStatus s) => s.name), <String>[
        'draft',
        'confirmed',
        'preparing',
        'ready',
        'completed',
        'cancelled',
      ]);
      // The refunded bill keeps the status every sales query already counts.
      expect(OrderStatus.completed.countsTowardsSales, isTrue);
    });

    test('it does not give the stock back', () {
      // The food was made and handed over. A reversing movement would claim ingredients are
      // on a shelf they are not on, and the cached balance would then over-sell.
      expect(RefundPolicy.reversesInventory, isFalse);
      // The same decision cancellation made, for the same reason.
      expect(OrderCancellation.reversesInventory, isFalse);
    });

    test('it does not rewrite kitchen history', () {
      expect(RefundPolicy.reversesKitchenHistory, isFalse);
      // And the kitchen board has no refunded state to be moved to.
      expect(
        KotStatus.values.map((KotStatus s) => s.name),
        isNot(contains('refunded')),
      );
    });

    test('it does not refund part of a bill in this step', () {
      expect(RefundPolicy.supportsPartialAmounts, isFalse);
    });

    test('it does not refund a split tender in this step', () {
      expect(RefundPolicy.supportsSplitTender, isFalse);
    });

    test('a settled refund uses the same status token as a settled tender', () {
      // One vocabulary for "money that has actually moved", so the reports cannot filter
      // tenders and reversals by two different rules.
      expect(RefundPolicy.settledStatus, PaymentStatus.completed);
      expect(RefundPolicy.completedRefundStatus, PaymentStatus.completed);
      expect(RefundPolicy.completedRefundStatus.isSettled, isTrue);
      // And no fifth tender type was added for refunds.
      expect(PaymentMethod.values, hasLength(4));
    });
  });

  group('the refundable figures', () {
    test('the remainder is the difference, to the paisa', () {
      expect(bill().refundableAmount.paise, 21000);
      expect(bill(refundedPaise: 6000).refundableAmount.paise, 15000);
      expect(bill(refundedPaise: 20999).refundableAmount.paise, 1);
      expect(bill(refundedPaise: 21000).refundableAmount.paise, 0);
    });

    test('the remainder is never negative', () {
      // A bill whose refunds somehow exceeded its tenders has nothing left, not a debt. A
      // negative remainder on a screen reads as an amount owed.
      final RefundableBill overRefunded = bill(refundedPaise: 30000);

      expect(overRefunded.refundableAmount.paise, 0);
      expect(overRefunded.refundableAmount.isNegative, isFalse);
      expect(overRefunded.isFullyRefunded, isTrue);
      expect(overRefunded.canRefund, isFalse);
    });

    test('a fully refunded bill says so and refuses another', () {
      final RefundableBill spent = bill(
        refundedPaise: 21000,
        existingRefund: reversal(),
      );

      expect(spent.isFullyRefunded, isTrue);
      expect(spent.hasRefund, isTrue);
      expect(spent.canRefund, isFalse);
      expect(spent.refusalReason, contains('already been refunded in full'));
    });

    test('a bill that collected nothing is not "fully refunded"', () {
      // A different situation with a different refusal: there was never any money to return.
      final RefundableBill untendered = bill(paidPaise: 0, tenders: 0);

      expect(untendered.isFullyRefunded, isFalse);
      expect(untendered.hasSettledPayment, isFalse);
      expect(untendered.canRefund, isFalse);
      expect(untendered.refusalReason, contains('No settled payment'));
    });

    test('an underpaid bill is flagged and refunds only what came in', () {
      final RefundableBill short = bill(paidPaise: 20000);

      expect(short.isUnderpaid, isTrue);
      expect(short.billTotal.paise, 21000);
      expect(short.refundableAmount.paise, 20000);
      // Flagged, but not blocked: the collected figure governs and a refund can proceed.
      expect(short.canRefund, isTrue);
    });

    test('a bill paid exactly is not flagged', () {
      expect(bill().isUnderpaid, isFalse);
    });

    test('the status refusal is reported before any money refusal', () {
      // A cancelled bill with a tender against it must be refused for being cancelled, which
      // is the fact the cashier needs, not for some arithmetic consequence of it.
      final RefundableBill cancelled = bill(status: OrderStatus.cancelled);

      expect(cancelled.refusalReason, contains('was cancelled'));
    });

    test('a split tender is refused after the money checks pass', () {
      final RefundableBill split = bill(paidPaise: 22000, tenders: 2);

      expect(split.hasSettledPayment, isTrue);
      expect(split.canRefund, isFalse);
      expect(split.refusalReason, contains('more than one payment'));
    });
  });

  group('a refund request', () {
    test('it carries the remainder the read model derived', () {
      final RefundableBill source = bill(refundedPaise: 6000);

      final RefundRequest request = RefundRequest.forBill(source);

      expect(request.orderId, 'ord-1');
      expect(request.amount.paise, 15000);
      expect(request.hasAmount, isTrue);
    });

    test('its id is stable, so a retry is a retry', () {
      final RefundableBill source = bill();
      final RefundRequest request = RefundRequest.forBill(source);

      // Holding the request is what makes a second attempt the same attempt.
      expect(request.id, request.id);
      expect(request.id, startsWith('ref-'));
    });

    test('two requests for the same bill are two different intents', () {
      final RefundableBill source = bill();

      final RefundRequest first = RefundRequest.forBill(source);
      final RefundRequest second = RefundRequest.forBill(source);

      // Building a fresh request is a second refund, not a repeat, and the repository
      // refuses it once the first has committed.
      expect(first.id, isNot(second.id));
    });

    test('a reason is trimmed, and a blank one becomes none', () {
      expect(
        RefundRequest.forBill(bill(), reason: '  Wrong order  ').reason,
        'Wrong order',
      );
      expect(RefundRequest.forBill(bill(), reason: '   ').reason, isNull);
      expect(RefundRequest.forBill(bill(), reason: '').reason, isNull);
      expect(RefundRequest.forBill(bill()).reason, isNull);
    });

    test('a request for nothing knows it is empty', () {
      final RefundRequest empty = RefundRequest.forBill(
        bill(refundedPaise: 21000),
      );

      expect(empty.amount.paise, 0);
      expect(empty.hasAmount, isFalse);
    });

    test('the requested instant is stored in UTC', () {
      final DateTime local = DateTime(2026, 4, 9, 15, 5);

      final RefundRequest request = RefundRequest.forBill(bill(), at: local);

      expect(request.requestedAt.isUtc, isTrue);
      expect(request.requestedAt, local.toUtc());
    });
  });

  group('the refund record', () {
    test('it stores a positive amount and carries its direction by table', () {
      final Refund written = reversal();

      // The sign is not the meaning. A negative amount would let any query that forgot which
      // table it was reading net a reversal against a sale.
      expect(written.amount.isPositive, isTrue);
      expect(written.amount.paise, 21000);
      expect(written.toMap()['amountPaise'], 21000);
    });

    test('it round-trips through a row exactly', () {
      final Refund written = reversal(reason: 'Wrong order');

      final Refund read = Refund.fromRow(
        written.toMap().cast<String, Object?>(),
      );

      expect(read.id, written.id);
      expect(read.orderId, written.orderId);
      expect(read.paymentId, written.paymentId);
      expect(read.orderNumberSnapshot, written.orderNumberSnapshot);
      expect(read.paymentMethod, written.paymentMethod);
      expect(read.amount.paise, written.amount.paise);
      expect(read.reason, written.reason);
      expect(read.status, written.status);
      expect(read.createdAt, written.createdAt);
      expect(read.isDeleted, isFalse);
    });

    test('only a completed reversal counts as money that has moved', () {
      expect(reversal().isSettled, isTrue);

      final Refund unconfirmed = reversal().copyWith(
        status: PaymentStatus.pending,
      );
      expect(unconfirmed.isSettled, isFalse);
    });

    test('an unrecognised stored status reads as not yet settled', () {
      // A status written by a newer build. Money this build cannot account for must never be
      // reported as having gone back.
      final Map<String, Object?> row =
          reversal().toMap().cast<String, Object?>()
            ..['status'] = 'someFutureState';

      expect(Refund.fromRow(row).status, PaymentStatus.pending);
      expect(Refund.fromRow(row).isSettled, isFalse);
    });

    test(
      'an unrecognised stored method reads as other rather than failing',
      () {
        final Map<String, Object?> row =
            reversal().toMap().cast<String, Object?>()
              ..['paymentMethod'] = 'someFutureTender';

        expect(Refund.fromRow(row).paymentMethod, PaymentMethod.other);
      },
    );
  });
}
