import '../../../../core/money/money.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../payments/domain/models/payment_method.dart';

/// One settled bill as it appears in the sales list.
///
/// ## What it is
///
/// The stored [Order] plus the three things a counter wants beside it that live in other
/// tables: how it was paid, the kitchen slip number, and who it was for. The repository
/// gathers all four in one statement rather than one query per row.
///
/// ## What it is not
///
/// It is not a cart and it cannot become one. Every value came out of `orders`,
/// `payments`, `kot_records` and `customers`, written at the moment of sale. Nothing here
/// or behind it reads the menu, so this list stays correct after a dish is repriced,
/// renamed or removed.
class SalesBill {
  const SalesBill({
    required this.order,
    this.paymentMethod,
    this.kotNumber,
    this.customerPhone,
    this.customerName,
    this.refundedAmount = Money.zero,
  });

  /// The stored bill header, with the amounts as charged.
  final Order order;

  /// How the bill was settled, or `null` when no settled tender is stored against it.
  ///
  /// `null` rather than a default. A bill with nothing recorded against it is a bill
  /// nobody should be told was paid in cash.
  final PaymentMethod? paymentMethod;

  /// The number on the kitchen slip raised for this bill, or `null` if none was.
  ///
  /// The earliest slip where more than one was raised, which is the number the counter
  /// and the kitchen used for the order.
  final String? kotNumber;

  /// The customer's number, or `null` for a walk-in who gave none.
  final String? customerPhone;

  /// The name recorded against that number, if one was given.
  final String? customerName;

  /// What has been handed back on this bill, positive. [Money.zero] when nothing has.
  ///
  /// The bill stays in this list at its full [total] after a refund, because the sale
  /// happened. This is how the list says so out loud rather than showing a reversed bill as
  /// an ordinary one.
  final Money refundedAmount;

  String get orderId => order.id;

  String get orderNumber => order.orderNumber;

  /// When the bill was taken, in UTC. Rendered in local time.
  DateTime get placedAt => order.createdAt;

  OrderType get orderType => order.orderType;

  /// Amount payable, as persisted. Never recomputed.
  Money get total => order.totalAmount;

  /// True when money has been handed back on this bill.
  bool get isRefunded => !refundedAmount.isZero;

  /// What the bill is left having earned: [total] less [refundedAmount].
  Money get netTotal => total - refundedAmount;

  /// True when the bill is filed against a customer record or carries a name.
  bool get hasCustomer => customerPhone != null ||
      (customerName != null && customerName!.trim().isNotEmpty);

  /// True when a kitchen slip number is stored for the bill.
  bool get hasKotNumber => kotNumber != null;

  @override
  String toString() => 'SalesBill($orderNumber, ${total.toDecimalString()})';
}
