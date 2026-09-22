import '../../../orders/domain/models/order_status.dart';
import '../../../payments/domain/models/payment_status.dart';

/// The single status move checkout makes, written down in one place.
///
/// ## What the move is
///
/// A cart is not an order. Nothing is written to the `orders` table while the
/// cashier is building the bill, so there is no `draft` row to advance: settlement
/// inserts the order already at [settledOrderStatus], together with its payment at
/// [settledPaymentStatus], inside one transaction. [startingOrderStatus] names the
/// state the bill conceptually leaves, which is why an unsettled bill has no row at
/// all and cannot appear in a sales figure.
///
/// This deliberately reuses `OrderStatus` and `PaymentStatus` rather than adding a
/// third status vocabulary. A separate "checkout state" enum would have to be kept in
/// agreement with both, and the first time it drifted a paid bill would report as
/// unpaid.
///
/// ## Why completed, now that kitchen slips exist
///
/// Settlement writes the order at [OrderStatus.completed] and raises a kitchen slip
/// at `KotStatus.pending`, both in the same transaction. The order status records
/// that the bill is financially settled, and it is: the money is in, and nothing
/// further is expected of the *bill*. `countsTowardsSales` and `isClosed` are both
/// true, which is what a paid bill is.
///
/// Preparation is tracked on the slip instead, and only on the slip. Keeping the two
/// apart is the point. If settlement produced `confirmed` and the kitchen advanced
/// the order through `preparing` and `ready`, then the order's status would answer
/// two different questions — has it been paid for, and has it been cooked — and a
/// paid bill waiting on the oven would read as an unfinished sale in every figure
/// derived from it. `OrderStatus.preparing` and `OrderStatus.ready` are therefore
/// left unused by this flow.
///
/// Cash, UPI and card are all recorded as [PaymentStatus.completed], because the
/// cashier only confirms once the money has actually arrived. `pending` exists for a
/// UPI attempt still being watched, which this flow does not create.
class CheckoutTransition {
  const CheckoutTransition._();

  /// Where a bill stands before it is settled: not yet a commitment, no row.
  static const OrderStatus startingOrderStatus = OrderStatus.draft;

  /// Status written for the order when the bill settles.
  static const OrderStatus settledOrderStatus = OrderStatus.completed;

  /// Status written for the payment when the bill settles.
  static const PaymentStatus settledPaymentStatus = PaymentStatus.completed;

  /// True when moving from [from] to [to] is the transition checkout performs.
  ///
  /// Exists so the rule can be asserted rather than assumed. Checkout is the only
  /// caller, and it only ever makes this one move.
  static bool isSettlement(OrderStatus from, OrderStatus to) =>
      from == startingOrderStatus && to == settledOrderStatus;
}
