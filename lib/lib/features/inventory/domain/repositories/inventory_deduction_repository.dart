import '../../../../core/utils/result.dart';
import '../models/order_inventory_deduction.dart';

/// Takes the stock a settled bill consumed off the shelf.
///
/// ## Why this is separate from settlement
///
/// Settlement is one transaction over the order, its lines, the payment and the
/// kitchen slip. Stock deduction is deliberately not in it.
///
/// The reason is a rule that cannot be compromised: **a payment is never rolled back
/// because a shelf was short.** If deduction joined the settlement transaction, a
/// recipe calling for 100 g of cheese when 50 g is recorded would abort the sale after
/// the customer had handed over the money. The right outcome in that situation is a
/// completed bill and a stock figure the operator has to correct, which is exactly
/// what this contract produces.
///
/// So the order is fixed: money and kitchen slip commit first, and this runs
/// afterwards, on its own, with its own transaction and its own record of how it went.
///
/// ## Why this is not a second outbox
///
/// It is not a queue and it does not retry on its own. It is a record of an operation
/// that has either been done or has not, with enough detail for an operator to finish
/// it. The existing outbox remains the one mechanism for reaching a backend, and this
/// adds nothing to that story; cloud synchronisation is a later milestone.
///
/// ## What it reads
///
/// Only the persisted bill and the configured recipes. Never the menu. The quantity,
/// the product reference and the size reference all come from the stored `order_items`
/// rows, so repricing an item, renaming it or discontinuing it cannot change or break
/// the deduction for a bill that has already been taken.
abstract interface class InventoryDeductionRepository {
  /// Deducts the stock consumed by the settled bill [orderId].
  ///
  /// Reads the bill's persisted lines, resolves each one's recipe — the size's own if
  /// it has one, the product's otherwise — multiplies each ingredient by the quantity
  /// sold, adds up everything that comes off the same shelf, and writes one `sale`
  /// stock movement per stock item with [orderId] as its reference.
  ///
  /// ## Idempotent
  ///
  /// Calling this repeatedly for the same bill deducts once. The second and every
  /// later call return the stored record without touching a balance. This holds even
  /// if a recipe was changed in between: what came off the shelf is in the ledger, and
  /// it is not recalculated.
  ///
  /// ## All or nothing
  ///
  /// If any ingredient is short, nothing at all is deducted, no balance moves, and the
  /// failure is recorded against the bill for the operator to resolve and retry. There
  /// is deliberately no partial deduction and no negative balance.
  ///
  /// ## Lines with no recipe
  ///
  /// Not an error and not a guess. A sold item with no recipe configured deducts
  /// nothing, is named in the record's `unconfiguredItems`, and does not stop the rest
  /// of the bill deducting. This is what lets the outlet go live with no recipes and
  /// configure them dish by dish.
  ///
  /// Returns a [ValidationFailure] when the bill is short of stock, or when [orderId]
  /// is not a settled bill.
  Future<Result<OrderInventoryDeduction>> deductForOrder(String orderId);

  /// The deduction record for one bill, or `null` if it has never been processed.
  Future<Result<OrderInventoryDeduction?>> findDeduction(String orderId);

  /// Bills whose stock was not deducted, newest first.
  ///
  /// The operator's work list. Each one is a settled sale whose stock figures are
  /// still outstanding, and each can be retried through [deductForOrder].
  Future<Result<List<OrderInventoryDeduction>>> loadFailedDeductions({
    int limit,
  });

  /// Bills that sold something with no recipe configured, newest first.
  ///
  /// Informational rather than a fault: these bills are processed and closed. The list
  /// exists so the operator can see which dishes are still unaccounted for and
  /// configure them.
  Future<Result<List<OrderInventoryDeduction>>> loadUnconfiguredDeductions({
    int limit,
  });
}
