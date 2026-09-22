import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import 'menu_item_type.dart';

/// A product the outlet sells.
class MenuItem implements SyncableEntity {
  const MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.itemType,
    required this.basePrice,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.isAvailable = true,
    this.isActive = true,
    this.displayOrder = 0,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory MenuItem.fromRow(Map<String, Object?> row) {
    return MenuItem(
      id: row.requireString(SyncColumns.id),
      categoryId: row.requireString('categoryId'),
      name: row.requireString('name'),
      description: row.optionalString('description'),
      itemType: row.requireEnum<MenuItemType>(
        'itemType',
        MenuItemType.values,
        fallback: MenuItemType.veg,
      ),
      basePrice: Money.fromPaise(row.requireInt('basePricePaise')),
      isAvailable: row.requireBool('isAvailable'),
      isActive: row.requireBool('isActive'),
      displayOrder: row.optionalInt('displayOrder'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String categoryId;

  final String name;

  final String? description;

  final MenuItemType itemType;

  /// Price when the item is sold without a size variant.
  ///
  /// For a size-priced product such as a pizza, the price actually charged comes
  /// from the chosen `MenuItemVariant`, and this holds the smallest size as a
  /// sensible default.
  final Money basePrice;

  /// Temporarily out of stock. Reversible during a shift, unlike [isActive].
  final bool isAvailable;

  final bool isActive;

  final int displayOrder;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// True when the item can be added to a bill right now.
  bool get isSellable => isActive && isAvailable && !isDeleted;

  MenuItem copyWith({
    String? categoryId,
    String? name,
    String? description,
    MenuItemType? itemType,
    Money? basePrice,
    bool? isAvailable,
    bool? isActive,
    int? displayOrder,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return MenuItem(
      id: id,
      categoryId: categoryId ?? this.categoryId,
      name: name ?? this.name,
      description: description ?? this.description,
      itemType: itemType ?? this.itemType,
      basePrice: basePrice ?? this.basePrice,
      isAvailable: isAvailable ?? this.isAvailable,
      isActive: isActive ?? this.isActive,
      displayOrder: displayOrder ?? this.displayOrder,
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
      'categoryId': categoryId,
      'name': name,
      'description': description,
      'itemType': itemType.name,
      'basePricePaise': basePrice.paise,
      'isAvailable': SqliteValue.fromBool(isAvailable),
      'isActive': SqliteValue.fromBool(isActive),
      'displayOrder': displayOrder,
    };
  }
}
