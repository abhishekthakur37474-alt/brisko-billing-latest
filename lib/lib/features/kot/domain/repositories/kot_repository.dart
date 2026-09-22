import '../../../../core/utils/result.dart';
import '../models/kitchen_ticket.dart';
import '../models/kot_item.dart';
import '../models/kot_item_option.dart';
import '../models/kot_record.dart';
import '../models/kot_status.dart';

/// Read and write access to kitchen slips.
///
/// Records what the kitchen was asked to make. Producing the paper slip is the
/// printing module's job and is not implemented yet.
///
/// Abstract for the same reason the other repositories are: the kitchen board is
/// written and tested against this contract and never learns that SQLite exists. No
/// SQL reaches a widget.
abstract interface class KotRepository {
  /// Creates a slip, its lines and their customisations atomically.
  ///
  /// Slips raised by settlement do not come through here: they are written inside
  /// the settlement transaction itself, because a paid bill with no slip is not an
  /// acceptable intermediate state. This method is for a slip raised on its own,
  /// after the bill was settled.
  Future<Result<void>> createKot(
    KotRecord record,
    List<KotItem> items, {
    List<KotItemOption> itemOptions,
  });

  Future<Result<KotRecord?>> findKot(String id);

  /// Slips raised against an order, oldest first. More than one is normal when
  /// items were added after the first slip went to the kitchen.
  Future<Result<List<KotRecord>>> loadForOrder(String orderId);

  Future<Result<List<KotItem>>> loadItems(String kotId);

  Future<Result<List<KotItemOption>>> loadItemOptions(String kotItemId);

  /// Slips still waiting to be printed, across all orders.
  Future<Result<List<KotRecord>>> loadPending();

  /// Everything the kitchen still has to deal with, newest first, with each slip's
  /// lines and their customisations already attached.
  ///
  /// This is the call the kitchen board makes. It returns slips in the pending,
  /// preparing and ready states; a completed or cancelled slip is history and a
  /// printed one belongs to the printing module.
  Future<Result<List<KitchenTicket>>> loadActiveTickets();

  /// Every slip raised against one order, oldest first, assembled the same way.
  ///
  /// Unlike [loadActiveTickets] this ignores the status, because a slip that has been
  /// cooked still has to be printable. This is the call the printing layer makes: it
  /// needs what the kitchen was asked for, whatever state that work is now in.
  Future<Result<List<KitchenTicket>>> loadTicketsForOrder(String orderId);

  /// Reserves the next slip number for today.
  Future<Result<String>> nextKotNumber();

  /// Moves a slip one step along the preparation workflow.
  ///
  /// The only accepted moves are pending to preparing and preparing to ready.
  /// Anything else — a repeat of the current state, a skipped state, or a move
  /// backwards — returns a `ValidationFailure` and writes nothing. The check reads
  /// the stored status inside the same transaction as the write, so two terminals
  /// pressing the same button cannot both succeed.
  Future<Result<void>> advanceStatus(String kotId, KotStatus next);

  /// Sets the status with no workflow check.
  ///
  /// For lifecycle moves that are not the kitchen's forward workflow, such as the
  /// printing module recording that paper was produced, or an order-level
  /// cancellation. Use [advanceStatus] for anything the kitchen board does.
  Future<Result<void>> updateStatus(String kotId, KotStatus status);
}
