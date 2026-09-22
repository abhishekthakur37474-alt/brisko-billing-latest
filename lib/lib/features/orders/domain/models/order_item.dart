import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';

/// One line on a bill.
///
/// ## Why the snapshots exist
///
/// [itemNameSnapshot], [variantNameSnapshot] and [unitPrice] are copies taken at
/// the moment of sale. They are not read from the menu when the bill is displayed
/// or reprinted.
///
/// This is the difference between a record and a query. If a line stored only
/// [menuItemId], then renaming "Farmhouse" or raising its price would silently
/// rewrite every bill that ever contained it: last month's totals would stop
/// matching last month's printed receipts and last month's GST return. Because the
/// values are captured here, history is immutable.
///
/// [menuItemId] is kept as a nullable back-reference for reporting only, and is
/// deliberately nullable so that deleting a discontinued product can never orphan
/// or destroy a historical bill.
class OrderItem implements SyncableEntity {
  const OrderItem({
    required this.id,
    required this.orderId,
    required this.itemNameSnapshot,
    required this.quantity,
    required this.unitPrice,
    required this.totalAmount,
    required this.createdAt,
    required this.updatedAt,
    this.menuItemId,
    this.variantId,
    this.variantNameSnapshot,
    this.discountAmount = Money.zero,
    this.taxAmount = Money.zero,
    this.notes,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory OrderItem.fromRow(Map<String, Object?> row) {
    return OrderItem(
      id: row.requireString(SyncColumns.id),
      orderId: row.requireString('orderId'),
      menuItemId: row.optionalString('menuItemId'),
      variantId: row.optionalString('variantId'),
      itemNameSnapshot: row.requireString('itemNameSnapshot'),
      variantNameSnapshot: row.optionalString('variantNameSnapshot'),
      quantity: row.requireInt('quantity'),
      unitPrice: Money.fromPaise(row.requireInt('unitPricePaise')),
      discountAmount: Money.fromPaise(row.requireInt('discountAmountPaise')),
      taxAmount: Money.fromPaise(row.requireInt('taxAmountPaise')),
      totalAmount: Money.fromPaise(row.requireInt('totalAmountPaise')),
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

  /// Reporting back-reference. Never the source of the printed name or price.
  final String? menuItemId;

  /// Reporting back-reference to the size chosen, if any.
  final String? variantId;

  /// Product name exactly as it appeared when sold.
  final String itemNameSnapshot;

  /// Size name exactly as it appeared when sold, or `null` if not size-priced.
  final String? variantNameSnapshot;

  final int quantity;

  /// Price of one unit as charged, including the chosen size.
  final Money unitPrice;

  final Money discountAmount;

  final Money taxAmount;

  /// Line total as charged.
  final Money totalAmount;

  final String? notes;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// Name as it should appear on a receipt, for example `Farmhouse (Medium)`.
  String get displayName => variantNameSnapshot == null
      ? itemNameSnapshot
      : '$itemNameSnapshot ($variantNameSnapshot)';

  /// Quantity times unit price, before discount and tax. Exact integer maths.
  ///
  /// Provided for checking a line, not for recomputing history: [totalAmount] is
  /// what was charged and may legitimately differ if an option was priced in.
  Money get grossAmount => unitPrice * quantity;

  OrderItem copyWith({
    int? quantity,
    Money? unitPrice,
    Money? discountAmount,
    Money? taxAmount,
    Money? totalAmount,
    String? notes,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return OrderItem(
      id: id,
      orderId: orderId,
      menuItemId: menuItemId,
      variantId: variantId,
      itemNameSnapshot: itemNameSnapshot,
      variantNameSnapshot: variantNameSnapshot,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      discountAmount: discountAmount ?? this.discountAmount,
      taxAmount: taxAmount ?? this.taxAmount,
      totalAmount: totalAmount ?? this.totalAmount,
      notes: notes ?? this.notes,
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
      'menuItemId': menuItemId,
      'variantId': variantId,
      'itemNameSnapshot': itemNameSnapshot,
      'variantNameSnapshot': variantNameSnapshot,
      'quantity': quantity,
      'unitPricePaise': unitPrice.paise,
      'discountAmountPaise': discountAmount.paise,
      'taxAmountPaise': taxAmount.paise,
      'totalAmountPaise': totalAmount.paise,
      'notes': notes,
    };
  }
}
