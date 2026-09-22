import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order.dart';
import '../models/bill_settlement.dart';

/// Writes a settled bill to local storage.
///
/// ## Why this is its own contract
///
/// Settling a bill touches four tables across two feature modules: the order header,
/// its lines, their options, and the payment. It has to be one transaction, because a
/// bill that exists without its payment reads as unpaid, and a payment without its
/// bill is money collected against nothing. The customer record joins that transaction
/// for the same reason: a customer created for a bill that then failed to write would be
/// a record of a sale that never happened.
///
/// That cannot be composed out of `OrderRepository` and `PaymentRepository`. Each owns
/// its own connection and opens its own transaction, so calling both would give two
/// commits and a window in between where the till is wrong. Billing is the module that
/// coordinates the sale, so the atomic write belongs here.
///
/// Abstract for the same reason the others are: the checkout controller is written and
/// tested against this contract and never learns that SQLite is underneath.
abstract interface class CheckoutRepository {
  /// Persists [settlement] — order, lines, line options and payment — atomically, and
  /// returns the order as written.
  ///
  /// The order number is allocated inside the transaction, so the returned [Order]
  /// carries the number that is actually in the table. The same is true of the customer:
  /// `BillSettlement.customerPhone` is resolved to an existing record or a new one
  /// inside the transaction, and the returned order's `customerId` is the reference that
  /// was stored. A name taken without a phone is stamped onto the order itself, so the
  /// bill still names who it was for. Nothing else about the settlement is changed:
  /// every name and price came from the cart and is written as given.
  ///
  /// On failure nothing at all is persisted and the failure is returned rather than
  /// thrown, so the caller still holds an intact cart and can retry. A retry of the
  /// same settlement rewrites the same rows and cannot produce a second bill, because
  /// every id was fixed when the settlement was built.
  ///
  /// Returns a [ValidationFailure] when the settlement has no lines, when its payment
  /// does not equal its total, or when it carries a phone number that is not usable.
  /// None can be checked by the schema, and the first two would corrupt every figure
  /// derived from the bill.
  Future<Result<Order>> settle(BillSettlement settlement);
}
