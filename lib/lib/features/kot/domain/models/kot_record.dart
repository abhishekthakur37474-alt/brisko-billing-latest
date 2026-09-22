import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../orders/domain/models/order_type.dart';
import 'kot_status.dart';

/// The header of a kitchen slip: which order it came from and where it stands.
///
/// ## Why the order details are copied here
///
/// [orderNumber], [orderType] and [notes] are snapshots taken when the slip was
/// raised, not lookups. The slip stands in for a piece of paper that was handed to
/// the kitchen, and the whole point of it is that its contents are fixed. Copying
/// also means the kitchen board reads one table: a screen that had to join back to
/// the order to find out whether it was a delivery would be one query away from
/// showing something the slip never said.
///
/// The values are stable by construction. An order number is allocated once and
/// never reissued, and an order's type is not editable after settlement, so the
/// copy cannot drift from the original.
class KotRecord implements SyncableEntity {
  const KotRecord({
    required this.id,
    required this.orderId,
    required this.orderNumber,
    required this.kotNumber,
    required this.orderType,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory KotRecord.fromRow(Map<String, Object?> row) {
    return KotRecord(
      id: row.requireString(SyncColumns.id),
      orderId: row.requireString('orderId'),
      orderNumber: row.requireString('orderNumber'),
      kotNumber: row.requireString('kotNumber'),
      orderType: row.requireEnum<OrderType>(
        'orderType',
        OrderType.values,
        fallback: OrderType.takeaway,
      ),
      status: row.requireEnum<KotStatus>(
        'status',
        KotStatus.values,
        fallback: KotStatus.pending,
      ),
      notes: row.optionalString('notes'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String orderId;

  /// Number printed on the bill, copied at the moment the slip was raised. This is
  /// what the counter and the kitchen say to each other.
  final String orderNumber;

  /// Number printed on the slip so the counter and kitchen can refer to it aloud.
  final String kotNumber;

  /// How the order leaves the counter, copied from the order. The kitchen plates a
  /// dine-in differently from a delivery.
  final OrderType orderType;

  final KotStatus status;

  /// Order-level instruction, copied from the order. For example `no onion`.
  final String? notes;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// True when this slip belongs on the kitchen board.
  bool get isActive => status.isActive;

  KotRecord copyWith({
    KotStatus? status,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return KotRecord(
      id: id,
      orderId: orderId,
      orderNumber: orderNumber,
      kotNumber: kotNumber,
      orderType: orderType,
      status: status ?? this.status,
      notes: notes,
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
      'orderNumber': orderNumber,
      'kotNumber': kotNumber,
      'orderType': orderType.name,
      'status': status.name,
      'notes': notes,
    };
  }
}
