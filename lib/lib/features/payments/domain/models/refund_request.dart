import '../../../../core/money/money.dart';
import '../../../../core/utils/entity_id.dart';
import 'refundable_bill.dart';

/// One attempt to hand money back on a settled bill.
///
/// ## The fixed id is the whole retry story
///
/// [id] is generated once, when the cashier's intent is formed, and is reused by every
/// retry of that same intent. The repository writes the refund under this id, so a second
/// attempt at the same request finds its own row and returns it rather than reversing the
/// money twice. This is the same technique `BillSettlement` uses for a settlement, and for
/// the same reason: the dangerous case is not a failure, it is a success whose
/// acknowledgement was lost.
///
/// A *different* request against a bill that is already refunded is a different thing
/// entirely, and is refused. Retrying is not the same as trying again.
///
/// ## The amount is carried, not calculated
///
/// [amount] arrives from [RefundableBill.refundableAmount] — a figure derived from
/// persisted paise — and is passed through untouched. Nothing here parses a decimal,
/// constructs an amount or does arithmetic on one. The repository still validates it
/// against what it reads inside its own transaction, because this figure was true when the
/// screen was drawn and the screen is not where money is decided.
class RefundRequest {
  const RefundRequest({
    required this.id,
    required this.orderId,
    required this.amount,
    required this.requestedAt,
    this.reason,
  });

  /// The request a screen makes for the whole of what is left on [bill].
  ///
  /// The id is generated here, so holding on to the returned request is what makes a retry
  /// a retry. Building a fresh one for the same bill is a second attempt, not a repeat, and
  /// will be refused once the first has committed.
  factory RefundRequest.forBill(
    RefundableBill bill, {
    String? reason,
    DateTime? at,
  }) {
    final String? trimmed = reason?.trim();
    return RefundRequest(
      id: EntityId.generate(prefix: 'ref'),
      orderId: bill.orderId,
      // The remainder as the read model derived it from stored paise.
      amount: bill.refundableAmount,
      requestedAt: at?.toUtc() ?? DateTime.now().toUtc(),
      reason: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }

  /// The identity the written refund will carry. Stable across retries.
  final String id;

  final String orderId;

  /// What the caller believes is refundable, positive.
  ///
  /// Checked against the persisted tenders inside the transaction that writes the refund. A
  /// figure larger than what was collected is refused; so, in this step, is a figure smaller
  /// than the remainder, because partial refunds are not supported.
  final Money amount;

  final DateTime requestedAt;

  /// The operator's note, trimmed, or `null` when none was given.
  final String? reason;

  /// True when the request asks for a positive amount.
  ///
  /// A refund of nothing is not a refund. Refused before the transaction opens, so a
  /// meaningless request writes nothing at all.
  bool get hasAmount => amount.isPositive;

  @override
  String toString() => 'RefundRequest($orderId, ${amount.toDecimalString()})';
}
