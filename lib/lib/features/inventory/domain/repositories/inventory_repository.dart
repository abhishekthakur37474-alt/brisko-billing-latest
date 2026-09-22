import '../../../../core/utils/result.dart';
import '../models/inventory_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_type.dart';

/// Read and write access to stock.
///
/// Basic tracking: items, a running balance, a ledger of every change, and a reorder
/// threshold. There is no warehouse, no transfer, no purchase order and no vendor.
///
/// ## The two invariants
///
/// Everything in this contract exists to hold two rules.
///
/// First, **a balance never moves without a ledger row**. Every operation that changes
/// [InventoryItem.currentQuantityMilli] writes a [StockMovement] in the same
/// transaction, so the balance can always be explained and, if it ever had to be,
/// rebuilt. That is also why [saveItem] cannot change a balance: editing an item is a
/// change to its name, unit or threshold, and a change to what is on the shelf is a
/// movement.
///
/// Second, **stock does not go negative**. A negative balance is not a small
/// inaccuracy, it is a figure that cannot be true, and once one exists every low-stock
/// report and every later count is measured against nonsense. An operation that would
/// produce one is refused with a [ValidationFailure] naming the item and the shortfall,
/// and nothing partial is applied.
abstract interface class InventoryRepository {
  /// Live, active items in name order.
  Future<Result<List<InventoryItem>>> loadItems();

  /// Emits the item list whenever it changes.
  Stream<List<InventoryItem>> watchItems();

  Future<Result<InventoryItem?>> findItem(String id);

  /// Items at or below their reorder threshold.
  ///
  /// Items with no threshold are excluded rather than reported as low, because a
  /// list that includes everything nobody has configured is a list nobody reads.
  Future<Result<List<InventoryItem>>> loadLowStockItems();

  /// Creates or edits a stock item.
  ///
  /// Returns a [ValidationFailure] when the name is blank, when the minimum quantity
  /// is negative, or when the balance of an item that already exists differs from the
  /// stored one. That last rule is the invariant above: a balance is moved by
  /// [stockIn], [adjust], [recordWastage] or [stockOut], never by saving an item over
  /// itself. A new item may be created with an opening balance of zero only, so that
  /// whatever is put on the shelf arrives through the ledger.
  Future<Result<void>> saveItem(InventoryItem item);

  /// Records stock arriving and adds it to the balance.
  ///
  /// [quantityMilli] is thousandths of the item's unit and must be positive.
  Future<Result<StockMovement>> stockIn({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  });

  /// Corrects a balance after a physical count.
  ///
  /// [quantityMilli] is signed: positive when the shelf holds more than the record
  /// says, negative when it holds less. Zero is refused, because a correction of
  /// nothing is not a correction. A correction that would take the balance below zero
  /// is refused.
  Future<Result<StockMovement>> adjust({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  });

  /// Records stock spoiled, dropped or otherwise lost, and subtracts it.
  ///
  /// [quantityMilli] must be positive and cannot exceed the current balance: an
  /// outlet cannot waste more than it holds, and accepting the figure would replace a
  /// counting mistake with an impossible balance.
  Future<Result<StockMovement>> recordWastage({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  });

  /// Records stock removed for a reason that is neither a sale nor a loss, and
  /// subtracts it.
  ///
  /// [quantityMilli] must be positive and cannot exceed the current balance.
  Future<Result<StockMovement>> stockOut({
    required String inventoryItemId,
    required int quantityMilli,
    String? reason,
  });

  /// Records a movement and adjusts the item's running balance atomically.
  ///
  /// The general form behind the four named operations above, and the one settlement
  /// uses to write a [StockMovementType.sale] with the order id as [referenceId].
  /// Prefer the named operations in presentation code: they say what happened, and
  /// they cannot be called with a sign that contradicts the type.
  ///
  /// [quantityMilli] is in thousandths of the item's unit. For every type except
  /// [StockMovementType.adjustment] it must be positive and the direction comes from
  /// the type; for an adjustment it is signed.
  ///
  /// Both writes are one transaction. If the balance update fails the ledger row
  /// rolls back, so there is no such thing as a half-applied movement.
  Future<Result<StockMovement>> recordMovement({
    required String inventoryItemId,
    required StockMovementType type,
    required int quantityMilli,
    String? reason,
    String? referenceId,
  });

  /// Ledger for one item, newest first.
  Future<Result<List<StockMovement>>> loadMovements(
    String inventoryItemId, {
    int limit,
  });

  /// Soft-deletes the item.
  ///
  /// Returns a [ValidationFailure] when a recipe still uses it. Allowing the deletion
  /// would leave every future sale of that dish unable to deduct, which is a failure
  /// the operator would meet one bill at a time instead of here, once.
  Future<Result<void>> deleteItem(String id);
}
