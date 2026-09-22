import '../../../../core/utils/result.dart';
import '../models/refund.dart';
import '../models/refund_request.dart';
import '../models/refundable_bill.dart';

/// Reads what a settled bill could have refunded, and writes the reversal.
///
/// ## Why this is not on `PaymentRepository`
///
/// `PaymentRepository` writes whole `Payment` entities through an upsert and has no
/// transaction of its own. A refund cannot be expressed that way: deciding it needs the
/// order's status, the bill's settled tenders and any reversal already written, and all
/// three have to be read in the same transaction that writes the row, or two cashiers
/// tapping at once both see an unrefunded bill. The guard and the write are one operation,
/// so they get a contract of their own — the same argument `CheckoutRepository` makes for
/// settlement.
///
/// ## What a refund touches
///
/// One row, in one table. The order, its lines, its options, its customer link, its kitchen
/// slip and — above all — its original payment are not written to at all. See
/// `RefundPolicy`, which names every one of those omissions as a decision.
///
/// ## Failure
///
/// Every method returns a `Result`. A refused refund is a `ValidationFailure` carrying
/// wording the cashier can act on; a storage fault is a `LocalStorageFailure`. Either way
/// nothing has been written, so the sale is exactly as it was and the attempt can be made
/// again.
abstract interface class RefundRepository {
  /// What could be refunded on the bill [orderId], or `null` when no such bill is stored.
  ///
  /// A read for display: the bill number, its total, what was collected, what has already
  /// gone back and the remainder. It authorises nothing — [refund] re-reads all of it — but
  /// it is what lets a screen show the figures and disable an action that would be refused.
  Future<Result<RefundableBill?>> loadRefundable(String orderId);

  /// Hands back the whole of what is left on the bill, in one transaction.
  ///
  /// Refuses, without writing anything, when the bill is not on this terminal, is not
  /// settled, has no settled tender, was settled with more than one tender, has already
  /// been refunded by a different request, or when [RefundRequest.amount] does not equal
  /// what the transaction itself reads as refundable.
  ///
  /// Idempotent for a repeat of the *same* request: if a refund already exists under
  /// [RefundRequest.id], it is returned unchanged and no second reversal is written. That is
  /// what makes retrying after a lost acknowledgement safe. A second, differently
  /// identified request against an already refunded bill is refused.
  ///
  /// Returns the refund as it was committed, read back from the row rather than from the
  /// values that were intended.
  Future<Result<Refund>> refund(RefundRequest request);

  /// Every reversal written against [orderId], oldest first.
  ///
  /// A list rather than a single value even though one refund per bill is all the schema
  /// currently allows, so that partial refunds arriving later change the query and not this
  /// signature.
  Future<Result<List<Refund>>> loadForOrder(String orderId);
}
