import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import 'payment_method.dart';
import 'payment_status.dart';

/// Money handed back on a bill that was settled.
///
/// A record of a reversal, sitting beside the tender it reverses rather than replacing it.
/// The [Payment] row keeps saying money arrived, because it did; this row says some of it
/// went back out again. Both are true and both are needed — the first reconciles the shift
/// the sale happened on, the second the shift the refund happened on.
///
/// ## The amount is positive
///
/// [amount] is what was given back, as a positive figure. The direction is carried by the
/// table this lives in, not by a sign, so a query that reads `refunds` cannot accidentally
/// net a reversal against a sale by forgetting which it was looking at. Callers that want a
/// signed figure negate it at the point of display.
///
/// ## Snapshots
///
/// [orderNumberSnapshot] and [paymentMethod] are copies taken when the refund was written,
/// like every other snapshot in this schema. A list of the day's refunds has to name the
/// bills it reversed and say how the money went back without depending on rows it is only
/// loosely about.
class Refund implements SyncableEntity {
  const Refund({
    required this.id,
    required this.orderId,
    required this.paymentId,
    required this.orderNumberSnapshot,
    required this.paymentMethod,
    required this.amount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.reason,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory Refund.fromRow(Map<String, Object?> row) {
    return Refund(
      id: row.requireString(SyncColumns.id),
      orderId: row.requireString('orderId'),
      paymentId: row.requireString('paymentId'),
      orderNumberSnapshot: row.requireString('orderNumberSnapshot'),
      paymentMethod: row.requireEnum<PaymentMethod>(
        'paymentMethod',
        PaymentMethod.values,
        // A method written by a newer build. Reported as `other` rather than failing the
        // read, which would make a refunded bill unopenable.
        fallback: PaymentMethod.other,
      ),
      amount: Money.fromPaise(row.requireInt('amountPaise')),
      reason: row.optionalString('reason'),
      status: row.requireEnum<PaymentStatus>(
        'status',
        PaymentStatus.values,
        // An unrecognised status reads as not-yet-settled, so money this build cannot
        // account for is never reported as having gone back.
        fallback: PaymentStatus.pending,
      ),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// The settled bill this reversed. Never changed by the refund.
  final String orderId;

  /// The tender the money went back against. Never changed by the refund.
  final String paymentId;

  /// The bill number as it read when the refund was written.
  final String orderNumberSnapshot;

  /// How the money went back, which for a reversal is how it came in.
  final PaymentMethod paymentMethod;

  /// What was given back, positive. Exact integer paise.
  final Money amount;

  /// Why, in the operator's own words. `null` when none was given.
  final String? reason;

  final PaymentStatus status;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// True once the money has actually gone back out.
  ///
  /// Only a settled refund reduces net sales or a customer's net spend. A reversal that
  /// has been recorded but not confirmed is not money that has left the till.
  bool get isSettled => status.isSettled;

  Refund copyWith({
    PaymentStatus? status,
    String? reason,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return Refund(
      id: id,
      orderId: orderId,
      paymentId: paymentId,
      orderNumberSnapshot: orderNumberSnapshot,
      paymentMethod: paymentMethod,
      amount: amount,
      reason: reason ?? this.reason,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      SyncColumns.id: id,
      SyncColumns.createdAt: SqliteValue.fromDateTime(createdAt),
      SyncColumns.updatedAt: SqliteValue.fromDateTime(updatedAt),
      SyncColumns.isDeleted: SqliteValue.fromBool(isDeleted),
      SyncColumns.syncState: syncState.name,
      'orderId': orderId,
      'paymentId': paymentId,
      'orderNumberSnapshot': orderNumberSnapshot,
      'paymentMethod': paymentMethod.name,
      'amountPaise': amount.paise,
      'reason': reason,
      'status': status.name,
    };
  }

  @override
  String toString() =>
      'Refund($orderNumberSnapshot, ${amount.toDecimalString()}, '
      '${status.name})';
}
