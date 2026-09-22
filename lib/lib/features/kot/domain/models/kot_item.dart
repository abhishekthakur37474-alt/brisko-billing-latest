import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';

/// One line on a kitchen slip.
///
/// Carries name snapshots for the same reason a bill line does, and for one more:
/// a slip is a physical document that was handed to the kitchen. Its contents must
/// remain exactly what was on the paper, whatever happens to the menu or to the
/// order afterwards.
///
/// No prices. The kitchen needs to know what to cook, not what it cost.
class KotItem implements SyncableEntity {
  const KotItem({
    required this.id,
    required this.kotId,
    required this.orderItemId,
    required this.itemNameSnapshot,
    required this.quantity,
    required this.createdAt,
    required this.updatedAt,
    this.variantNameSnapshot,
    this.notes,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory KotItem.fromRow(Map<String, Object?> row) {
    return KotItem(
      id: row.requireString(SyncColumns.id),
      kotId: row.requireString('kotId'),
      orderItemId: row.requireString('orderItemId'),
      itemNameSnapshot: row.requireString('itemNameSnapshot'),
      variantNameSnapshot: row.optionalString('variantNameSnapshot'),
      quantity: row.requireInt('quantity'),
      notes: row.optionalString('notes'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String kotId;

  /// The bill line this slip line came from.
  final String orderItemId;

  final String itemNameSnapshot;

  final String? variantNameSnapshot;

  final int quantity;

  /// Preparation instruction, for example `no onion`.
  final String? notes;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// Name as it should appear on the slip.
  String get displayName => variantNameSnapshot == null
      ? itemNameSnapshot
      : '$itemNameSnapshot ($variantNameSnapshot)';

  KotItem copyWith({
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return KotItem(
      id: id,
      kotId: kotId,
      orderItemId: orderItemId,
      itemNameSnapshot: itemNameSnapshot,
      variantNameSnapshot: variantNameSnapshot,
      quantity: quantity,
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
      'kotId': kotId,
      'orderItemId': orderItemId,
      'itemNameSnapshot': itemNameSnapshot,
      'variantNameSnapshot': variantNameSnapshot,
      'quantity': quantity,
      'notes': notes,
    };
  }
}
