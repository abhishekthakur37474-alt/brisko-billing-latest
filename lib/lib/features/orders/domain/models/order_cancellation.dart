import '../../../kot/domain/models/kot_status.dart';
import 'order_status.dart';

/// What cancelling a written bill does, and deliberately does not do.
///
/// ## Why this is a class of constants rather than code
///
/// Cancellation is a status change. Almost all of its correctness lies in what it
/// leaves alone: the amounts, the lines, the tender, the kitchen slip's contents, the
/// stock that was already taken. An omission is invisible in a repository method — it
/// reads as code that was never written rather than as a decision — so each omission is
/// named here and asserted in the tests. `OrderCancellation.reversesInventory` being
/// `false` is a statement; a missing stock write is an absence.
///
/// This mirrors `CheckoutTransition`, which does the same for the one status move
/// settlement makes.
///
/// ## No second vocabulary
///
/// [cancelledStatus] is the existing [OrderStatus.cancelled], not a new value. Reports
/// and customer totals already count only [OrderStatus.completed], so a cancelled bill
/// drops out of the takings, the item sales, the payment mix and the customer's spend
/// with no query changing. Adding a parallel "cancellation state" would have to be kept
/// in agreement with `OrderStatus`, and the first time the two drifted a cancelled bill
/// would still be counted as a sale.
class OrderCancellation {
  const OrderCancellation._();

  /// The status a cancelled bill is written at.
  ///
  /// Both `countsTowardsSales` and `isClosed` already answer correctly for it, which is
  /// why nothing downstream of the orders table needed changing.
  static const OrderStatus cancelledStatus = OrderStatus.cancelled;

  /// Kitchen slip states that a cancellation stops.
  ///
  /// A bill nobody is paying for must not leave food being cooked for it, so outstanding
  /// work is moved to [KotStatus.cancelled]. `KotStatus.completed` is absent on purpose:
  /// the food was made and handed over, and rewriting that slip as cancelled would claim
  /// it never happened. `KotStatus.printed` is likewise left to the printing module.
  ///
  /// This is an order-level action, which is why it does not go through
  /// `KotStatus.canAdvanceTo`. The kitchen board's forward workflow is
  /// pending -> preparing -> ready and cancellation is reachable from none of those
  /// steps; only cancelling the bill can set it.
  static const List<KotStatus> cancellableKotStatuses = <KotStatus>[
    KotStatus.pending,
    KotStatus.preparing,
    KotStatus.ready,
  ];

  /// Whether cancelling gives the deducted stock back. It does not.
  ///
  /// The ingredients were consumed when the food was made, and a bill is usually
  /// cancelled after that point. Writing a reversing movement would claim stock is on
  /// the shelf that is not, and the cached balance on the item would then be wrong in
  /// the direction that causes over-selling. Correcting real stock is what a manual
  /// adjustment is for, and it is a separate, deliberate act.
  ///
  /// The original sale movements and the order's deduction record are therefore both
  /// left exactly as they are, not soft-deleted: nothing adjusts the cached balance on
  /// delete, so hiding the ledger rows would desync it.
  static const bool reversesInventory = false;

  /// Whether cancelling undoes the payment. It does not.
  ///
  /// The money did arrive, and the tender row says so. Giving it back is a refund, which
  /// is a movement of money in its own right and is not implemented. The tender stays
  /// `completed` and simply stops joining to a settled bill, which is what takes it out
  /// of the payment mix.
  static const bool reversesPayment = false;

  /// True when a bill at [from] can still be cancelled.
  ///
  /// Everything except an already-cancelled bill. A bill at any live stage can be
  /// cancelled — settled, or still being prepared — because the reason for cancelling
  /// arrives from outside the workflow rather than at a particular step in it. The one
  /// refusal is the second cancellation, so two cashiers acting at once resolve to one
  /// winner instead of both reporting success.
  static bool canCancel(OrderStatus from) => from != cancelledStatus;

  /// Why a bill at [from] cannot be cancelled, or `null` when it can.
  ///
  /// Operator-facing wording, kept beside the rule it explains so the two cannot drift.
  static String? refusalReason(OrderStatus from) =>
      canCancel(from) ? null : 'This bill is already cancelled.';
}
