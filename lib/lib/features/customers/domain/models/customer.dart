import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';

/// A customer, identified in practice by phone number.
///
/// Deliberately minimal. There are no order count, total spend or last visit
/// columns, because those are answers derivable from the `orders` table and
/// duplicating them here would create two sources of truth that drift apart the
/// first time a bill is cancelled. Order history is a query, not a stored field.
class Customer implements SyncableEntity {
  const Customer({
    required this.id,
    required this.phone,
    required this.createdAt,
    required this.updatedAt,
    this.name,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory Customer.fromRow(Map<String, Object?> row) {
    return Customer(
      id: row.requireString(SyncColumns.id),
      name: row.optionalString('name'),
      phone: row.requireString('phone'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// Optional: a delivery order often has a number but no name yet.
  final String? name;

  /// Lookup key at the counter. Stored as entered, digits only by convention.
  final String phone;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// What to show when the customer has no name recorded.
  String get displayName =>
      (name == null || name!.trim().isEmpty) ? phone : name!;

  Customer copyWith({
    String? name,
    String? phone,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return Customer(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
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
      'name': name,
      'phone': phone,
    };
  }
}
