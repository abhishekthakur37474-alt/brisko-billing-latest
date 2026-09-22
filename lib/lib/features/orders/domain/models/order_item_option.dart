import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';

/// A customisation applied to one bill line, such as Extra Cheese.
///
/// Like [OrderItem], this stores a name and price snapshot rather than pointing at
/// the live menu option, so that re-pricing Extra Cheese tomorrow cannot alter what
/// today's bill says it charged.
class OrderItemOption implements SyncableEntity {
  const OrderItemOption({
    required this.id,
    required this.orderItemId,
    required this.optionNameSnapshot,
    required this.price,
    required this.createdAt,
    required this.updatedAt,
    this.optionId,
    this.quantity = 1,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory OrderItemOption.fromRow(Map<String, Object?> row) {
    return OrderItemOption(
      id: row.requireString(SyncColumns.id),
      orderItemId: row.requireString('orderItemId'),
      optionId: row.optionalString('optionId'),
      optionNameSnapshot: row.requireString('optionNameSnapshot'),
      price: Money.fromPaise(row.requireInt('pricePaise')),
      quantity: row.optionalInt('quantity', fallback: 1),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String orderItemId;

  /// Reporting back-reference to the menu option. Never the source of the name or
  /// price on the bill.
  final String? optionId;

  final String optionNameSnapshot;

  /// Price of one unit of this option as charged.
  final Money price;

  /// How many were added, for stackable options such as extra toppings.
  final int quantity;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// Amount this option contributed to the line. Exact integer maths.
  Money get totalAmount => price * quantity;

  OrderItemOption copyWith({
    int? quantity,
    Money? price,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return OrderItemOption(
      id: id,
      orderItemId: orderItemId,
      optionId: optionId,
      optionNameSnapshot: optionNameSnapshot,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
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
      'orderItemId': orderItemId,
      'optionId': optionId,
      'optionNameSnapshot': optionNameSnapshot,
      'pricePaise': price.paise,
      'quantity': quantity,
    };
  }
}
