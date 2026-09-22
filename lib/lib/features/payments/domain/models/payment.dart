import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import 'payment_method.dart';
import 'payment_status.dart';

/// One tender against an order.
///
/// An order has many payments, not one. Even though the outlet currently settles a
/// bill with a single method, modelling it as a collection now is what makes split
/// payment, part cash and part UPI, an insert rather than a migration. Storing
/// `paymentMethod` and `amount` on the order itself would have to be undone to
/// support it.
class Payment implements SyncableEntity {
  const Payment({
    required this.id,
    required this.orderId,
    required this.paymentMethod,
    required this.amount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.reference,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory Payment.fromRow(Map<String, Object?> row) {
    return Payment(
      id: row.requireString(SyncColumns.id),
      orderId: row.requireString('orderId'),
      paymentMethod: row.requireEnum<PaymentMethod>(
        'paymentMethod',
        PaymentMethod.values,
        fallback: PaymentMethod.other,
      ),
      amount: Money.fromPaise(row.requireInt('amountPaise')),
      reference: row.optionalString('reference'),
      status: row.requireEnum<PaymentStatus>(
        'status',
        PaymentStatus.values,
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

  final String orderId;

  final PaymentMethod paymentMethod;

  final Money amount;

  /// UPI transaction id, card approval code, or aggregator settlement note.
  final String? reference;

  final PaymentStatus status;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  Payment copyWith({
    PaymentMethod? paymentMethod,
    Money? amount,
    String? reference,
    PaymentStatus? status,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return Payment(
      id: id,
      orderId: orderId,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      amount: amount ?? this.amount,
      reference: reference ?? this.reference,
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
      'paymentMethod': paymentMethod.name,
      'amountPaise': amount.paise,
      'reference': reference,
      'status': status.name,
    };
  }
}
