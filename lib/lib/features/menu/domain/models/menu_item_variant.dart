import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';

/// A size of a product with its own price, such as a Medium pizza.
///
/// Variants are rows rather than columns because the number of sizes differs by
/// product and can change. An item with no variant rows is sold at a single price.
class MenuItemVariant implements SyncableEntity {
  const MenuItemVariant({
    required this.id,
    required this.menuItemId,
    required this.name,
    required this.price,
    required this.displayOrder,
    required this.createdAt,
    required this.updatedAt,
    this.isActive = true,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory MenuItemVariant.fromRow(Map<String, Object?> row) {
    return MenuItemVariant(
      id: row.requireString(SyncColumns.id),
      menuItemId: row.requireString('menuItemId'),
      name: row.requireString('name'),
      price: Money.fromPaise(row.requireInt('pricePaise')),
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

  final String menuItemId;

  /// For example `Small`, `Medium`, `Large`.
  final String name;

  /// Absolute price for this size, not a difference from the base price. Storing
  /// the full price keeps the amount charged unambiguous on the bill.
  final Money price;

  final int displayOrder;

  final bool isActive;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  MenuItemVariant copyWith({
    String? name,
    Money? price,
    int? displayOrder,
    bool? isActive,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return MenuItemVariant(
      id: id,
      menuItemId: menuItemId,
      name: name ?? this.name,
      price: price ?? this.price,
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
      'menuItemId': menuItemId,
      'name': name,
      'pricePaise': price.paise,
      'displayOrder': displayOrder,
      'isActive': SqliteValue.fromBool(isActive),
    };
  }
}
