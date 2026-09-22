import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';

/// A menu section, such as Veg Pizza or Cold Drinks.
class MenuCategory implements SyncableEntity {
  const MenuCategory({
    required this.id,
    required this.name,
    required this.displayOrder,
    required this.createdAt,
    required this.updatedAt,
    this.isActive = true,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory MenuCategory.fromRow(Map<String, Object?> row) {
    return MenuCategory(
      id: row.requireString(SyncColumns.id),
      name: row.requireString('name'),
      displayOrder: row.optionalInt('displayOrder'),
      isActive: row.requireBool('isActive'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String name;

  /// Position at the counter. Lower sorts first.
  final int displayOrder;

  /// A category switched off is hidden from billing but keeps its history.
  /// Distinct from [isDeleted], which means removed.
  final bool isActive;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  MenuCategory copyWith({
    String? name,
    int? displayOrder,
    bool? isActive,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return MenuCategory(
      id: id,
      name: name ?? this.name,
      displayOrder: displayOrder ?? this.displayOrder,
      isActive: isActive ?? this.isActive,
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
      'displayOrder': displayOrder,
      'isActive': SqliteValue.fromBool(isActive),
    };
  }
}
