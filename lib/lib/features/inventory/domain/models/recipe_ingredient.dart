import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import 'recipe_scope.dart';
import 'stock_quantity.dart';

/// One line of a recipe: how much of one stock item a single sold unit uses.
///
/// ## Per sold unit, never per bill line
///
/// [quantityMilli] is the amount for exactly one of the thing. Selling three pizzas
/// multiplies it by three at deduction time. Storing it per unit means the recipe
/// stays a statement about the dish, and the only arithmetic between a recipe and a
/// stock movement is one multiplication by an integer quantity — so nothing rounds and
/// nothing drifts.
///
/// ## Why this is a live reference, not a snapshot
///
/// Everything on a bill is snapshotted, because a bill is a historical document. A
/// recipe is the opposite: it is current configuration, describing how the kitchen
/// makes the dish today. So [inventoryItemId] and [menuItemId] are real references,
/// and correcting a recipe corrects it for future sales.
///
/// That is also why deduction is idempotent rather than recomputable. Once a bill has
/// been deducted, the amounts that came off the shelf are recorded in the stock
/// ledger, and changing this row afterwards must not reopen that. The ledger holds
/// what was taken; this row holds what will be taken next time.
class RecipeIngredient implements SyncableEntity {
  const RecipeIngredient({
    required this.id,
    required this.menuItemId,
    required this.inventoryItemId,
    required this.quantityMilli,
    required this.createdAt,
    required this.updatedAt,
    this.variantId,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory RecipeIngredient.fromRow(Map<String, Object?> row) {
    return RecipeIngredient(
      id: row.requireString(SyncColumns.id),
      menuItemId: row.requireString('menuItemId'),
      variantId: row.optionalString('variantId'),
      inventoryItemId: row.requireString('inventoryItemId'),
      quantityMilli: row.requireInt('quantityMilli'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// The product this line belongs to.
  final String menuItemId;

  /// The size this line belongs to, or `null` for a product-level recipe.
  final String? variantId;

  /// The stock item consumed.
  final String inventoryItemId;

  /// Amount used by one sold unit, in thousandths of the stock item's unit.
  final int quantityMilli;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// Which recipe this line is part of.
  RecipeScope get scope => variantId == null
      ? RecipeScope.product(menuItemId)
      : RecipeScope.variant(menuItemId: menuItemId, variantId: variantId!);

  String get quantityDisplay => StockQuantity.format(quantityMilli);

  /// The amount [soldQuantity] units of this dish consume. Exact integer maths.
  int requiredFor(int soldQuantity) =>
      StockQuantity.forQuantity(quantityMilli, soldQuantity);

  RecipeIngredient copyWith({
    int? quantityMilli,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return RecipeIngredient(
      id: id,
      menuItemId: menuItemId,
      variantId: variantId,
      inventoryItemId: inventoryItemId,
      quantityMilli: quantityMilli ?? this.quantityMilli,
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
      'variantId': variantId,
      'inventoryItemId': inventoryItemId,
      'quantityMilli': quantityMilli,
    };
  }
}
