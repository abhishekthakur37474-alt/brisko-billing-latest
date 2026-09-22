import '../../../../core/money/money.dart';
import '../../../orders/domain/models/order_status.dart';
import 'payment_method.dart';
import 'refund.dart';
import 'refund_policy.dart';

/// What a stored bill has taken in, what has already gone back out, and therefore what
/// could still be refunded.
///
/// ## Why this exists rather than three loose values
///
/// A refund screen has to show four figures that must agree with each other: the bill
/// total, the amount actually collected, the amount already refunded and the remainder.
/// Passing those around separately is how a screen comes to display a remainder that is
/// not the difference of the other two. Here [refundableAmount] is derived, so it cannot
/// disagree, and [canRefund] answers from the same values the figures are drawn from.
///
/// ## Every figure is persisted, none is recomputed
///
/// [paidAmount] is the sum of the bill's settled tenders as stored, not the bill total.
/// They are normally equal, and where they are not the collected figure is the one a
/// refund is limited by: money that never arrived cannot be sent back. [refundedAmount] is
/// the sum of the bill's settled refunds as stored. Nothing here reads the menu, and
/// nothing recalculates a line.
///
/// ## This is a read model
///
/// It answers questions and authorises nothing. The repository re-reads all of it inside
/// the transaction that writes the refund, because anything read for display is already
/// stale by the time the cashier taps a button.
class RefundableBill {
  const RefundableBill({
    required this.orderId,
    required this.orderNumber,
    required this.orderStatus,
    required this.billTotal,
    required this.paidAmount,
    required this.refundedAmount,
    required this.settledTenderCount,
    this.paymentMethod,
    this.existingRefund,
  });

  final String orderId;

  /// The bill number, for a confirmation the cashier can check against the paper.
  final String orderNumber;

  /// The stored status. A refund is only legal from `RefundPolicy.refundableOrderStatus`.
  final OrderStatus orderStatus;

  /// The bill's persisted total, as charged.
  final Money billTotal;

  /// Sum of the settled tenders against the bill. The ceiling on a refund.
  final Money paidAmount;

  /// Sum of the settled refunds already written against the bill.
  final Money refundedAmount;

  /// How many settled tenders the bill has.
  ///
  /// Carried because more than one is a case this step refuses rather than guesses at; see
  /// `RefundPolicy.supportsSplitTender`.
  final int settledTenderCount;

  /// How the bill was settled, and therefore how a refund would go back. `null` when no
  /// settled tender is stored.
  final PaymentMethod? paymentMethod;

  /// The reversal already written against this bill, if there is one.
  ///
  /// Held so a screen can show when the refund happened and why, rather than only that the
  /// bill is spent.
  final Refund? existingRefund;

  /// True when a reversal has already been written against this bill.
  bool get hasRefund => existingRefund != null;

  /// What could still be sent back.
  ///
  /// Derived, never stored. Clamped at zero rather than allowed to go negative: a bill
  /// whose refunds somehow exceeded its tenders has nothing left to refund, and a negative
  /// remainder rendered on a screen would read as an amount owed.
  Money get refundableAmount =>
      refundedAmount >= paidAmount ? Money.zero : paidAmount - refundedAmount;

  /// True when everything that was collected has been sent back.
  ///
  /// False for a bill that collected nothing: there is no money to have returned, which is
  /// a different situation and carries a different refusal.
  bool get isFullyRefunded =>
      paidAmount.isPositive && refundedAmount >= paidAmount;

  /// True when money was actually collected against this bill.
  bool get hasSettledPayment => settledTenderCount > 0 && paidAmount.isPositive;

  /// True when the bill's own total and the amount collected disagree.
  ///
  /// Surfaced rather than smoothed over. It does not block a refund — the collected figure
  /// governs — but whoever is handing money back is entitled to know the two figures on the
  /// record do not match.
  bool get isUnderpaid => paidAmount != billTotal;

  /// True when a refund can be attempted right now.
  ///
  /// The screen enables its action from this, and the repository re-decides the same
  /// question inside its transaction. Both go through [RefundPolicy], so the button and the
  /// write cannot disagree about the rule, only about how stale their reads are.
  bool get canRefund => refusalReason == null;

  /// Why a refund cannot be attempted, or `null` when it can.
  ///
  /// Ordered from the most fundamental refusal to the most specific, so the cashier is told
  /// the first thing that is actually wrong rather than a consequence of it.
  String? get refusalReason {
    final String? statusRefusal = RefundPolicy.refusalReason(orderStatus);
    if (statusRefusal != null) {
      return statusRefusal;
    }
    if (isFullyRefunded) {
      return 'This bill has already been refunded in full.';
    }
    if (hasRefund) {
      return 'This bill has already been refunded.';
    }
    if (!hasSettledPayment) {
      return 'No settled payment is recorded against this bill, so there is '
          'nothing to refund.';
    }
    if (settledTenderCount > 1 && !RefundPolicy.supportsSplitTender) {
      return 'This bill was settled with more than one payment. Refunding a '
          'split payment is not supported on this terminal.';
    }
    if (!refundableAmount.isPositive) {
      return 'There is nothing left to refund on this bill.';
    }
    return null;
  }

  @override
  String toString() =>
      'RefundableBill($orderNumber, paid ${paidAmount.toDecimalString()}, '
      'refunded ${refundedAmount.toDecimalString()})';
}
