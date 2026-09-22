import '../../../orders/domain/models/order_status.dart';
import 'payment_status.dart';

/// What refunding a settled bill does, and deliberately does not do.
///
/// ## Why this is a class of constants rather than code
///
/// Almost all of a refund's correctness lies in what it leaves alone: the original
/// tender, the order's status and totals, the lines, the kitchen slip, the stock that was
/// consumed. An omission is invisible in a repository method — it reads as code nobody got
/// round to writing rather than as a decision — so each omission is named here and
/// asserted in the tests. [reversesInventory] being `false` is a statement; a missing
/// stock write is an absence.
///
/// This mirrors `OrderCancellation`, which does the same for cancellation, and
/// `CheckoutTransition`, which does it for settlement.
///
/// ## No second order vocabulary
///
/// A refund does not move the order's status, and there is no `OrderStatus.refunded`.
/// The sale happened: it keeps [refundableOrderStatus] forever, so gross sales, the item
/// report and the bill list all continue to show it exactly as it was rung up. What a
/// refund adds is a second fact recorded beside the first, in its own table. Net sales is
/// gross minus that table.
///
/// Adding a status would have meant deciding whether a refunded bill "counts towards
/// sales", and either answer is wrong: it counts towards gross and not towards net. A
/// single status cannot hold two answers, and the first time the two drifted a reversed
/// bill would be either double counted or invisible.
class RefundPolicy {
  const RefundPolicy._();

  /// The only status a bill can be refunded from.
  ///
  /// Money can only be given back if it was taken, and `OrderStatus.completed` is the
  /// status `CheckoutTransition` writes when it was. A draft never reaches the orders
  /// table, a `confirmed`, `preparing` or `ready` bill has not been settled, and a
  /// cancelled bill was reversed before any money moved.
  static const OrderStatus refundableOrderStatus = OrderStatus.completed;

  /// The status a tender must have for its money to be refundable.
  ///
  /// The same `PaymentStatus.completed` that `CheckoutTransition.settledPaymentStatus`
  /// writes and that every "amount collected" query filters on. A pending UPI attempt is
  /// not money in, so there is nothing to send back.
  static const PaymentStatus settledStatus = PaymentStatus.completed;

  /// The status a refund is recorded at once the money has gone back.
  ///
  /// The same token as [settledStatus], from the same enum, so that "money that has
  /// actually moved" is one idea across tenders and reversals rather than two that have to
  /// be kept in agreement.
  static const PaymentStatus completedRefundStatus = PaymentStatus.completed;

  /// Whether refunding rewrites the tender it reverses. It does not.
  ///
  /// The original payment row keeps its amount, its method, its reference, its `createdAt`
  /// and its `completed` status. That row is the record that money arrived, and it did.
  /// Overwriting its status to `refunded` would erase the arrival to describe the
  /// departure, and the till reconciliation for the shift the money came in on would stop
  /// adding up.
  ///
  /// The reversal is a row in `refunds` pointing at the tender, which is why both facts
  /// survive.
  static const bool reversesOriginalPayment = false;

  /// Whether refunding moves the order's status. It does not. See the class comment.
  static const bool changesOrderStatus = false;

  /// Whether refunding gives the deducted stock back. It does not.
  ///
  /// The same reasoning as `OrderCancellation.reversesInventory`, and one more besides.
  /// The food was made and handed over; a refund is usually agreed after that. Writing a
  /// reversing movement would claim ingredients are on the shelf that are not, and the
  /// cached balance on the item would then be wrong in the direction that causes
  /// over-selling.
  ///
  /// There is also no safe reversal model to reuse. `order_inventory_deductions` is keyed
  /// one row per order and records that the deduction happened; it has no notion of an
  /// undo, so a reversal would either have to overwrite that record — losing the fact that
  /// stock was taken — or write movements with no record keeping them idempotent, which a
  /// retried refund would then duplicate.
  ///
  /// A manual stock adjustment is what corrects real stock, and it must stay a separate,
  /// deliberate act by someone who has looked at the shelf. In particular a refund must
  /// never write `StockMovementType.adjustment` on the operator's behalf: that would put
  /// an automatic movement in the ledger dressed as a human decision, and the ledger would
  /// no longer be able to tell the two apart.
  ///
  /// Reversing stock on refund is a later step and needs an idempotent reversal model of
  /// its own.
  static const bool reversesInventory = false;

  /// Whether refunding rewrites kitchen history. It does not.
  ///
  /// A slip that was printed was printed, and a slip marked completed records food that
  /// was cooked and handed over. Cancelling those after the fact would claim the kitchen
  /// never did the work. Unlike cancellation, a refund cannot even have outstanding work
  /// to stop: it is only reachable from a settled bill, and settlement and the kitchen
  /// slip are the same commit.
  ///
  /// `KotStatus` has no refunded state and is not given one. The board shows what the
  /// kitchen has to do; money going back out is not kitchen work.
  static const bool reversesKitchenHistory = false;

  /// Whether part of a bill can be refunded. Not in this step.
  ///
  /// The unique index on `refunds.orderId` allows one reversal per bill, so the amount is
  /// always the whole of what was collected. Partial and line-level refunds are a real
  /// feature and a substantially larger one: they need the index relaxed, an allocation
  /// rule for how a bill-level discount and tax attach to a single line, a running
  /// refunded-so-far balance per line, and a decision about what a partly refunded bill
  /// contributes to item sales. None of that is invented here on the way past. It is a
  /// later step.
  static const bool supportsPartialAmounts = false;

  /// Whether a bill settled with more than one tender can be refunded. Not in this step.
  ///
  /// Split payment is not implemented — `BillSettlement` writes exactly one tender — so
  /// this case does not arise from anything the application can currently do. It is
  /// refused rather than guessed at, because sending the whole amount back by one of two
  /// methods is a decision about someone else's money.
  static const bool supportsSplitTender = false;

  /// True when a bill at [from] can be refunded.
  ///
  /// Exactly one status qualifies, which is the opposite shape to
  /// `OrderCancellation.canCancel`: cancelling is legal from everywhere except a repeat,
  /// because its reason arrives from outside the workflow. Refunding is legal from one
  /// place only, because it is a movement of money and there is only one status in which
  /// money has moved.
  static bool canRefund(OrderStatus from) => from == refundableOrderStatus;

  /// Why a bill at [from] cannot be refunded, or `null` when it can.
  ///
  /// Operator-facing wording, kept beside the rule it explains so the two cannot drift.
  /// Each case says what the bill is rather than only that the answer is no, because the
  /// cashier's next action differs: a draft has to be settled, a cancelled bill never took
  /// the money.
  static String? refusalReason(OrderStatus from) {
    if (canRefund(from)) {
      return null;
    }
    return switch (from) {
      OrderStatus.draft =>
        'This bill is still a draft, so no money has been taken to refund.',
      OrderStatus.cancelled =>
        'This bill was cancelled, so no money was taken to refund.',
      OrderStatus.confirmed || OrderStatus.preparing || OrderStatus.ready =>
        'This bill has not been settled yet, so there is nothing to refund.',
      OrderStatus.completed => null,
    };
  }
}
