import '../../../../core/utils/result.dart';
import '../models/held_bill.dart';
import '../models/held_bill_draft.dart';
import '../models/held_bill_summary.dart';

/// Puts bills aside at the counter, brings them back, and lets them go.
///
/// ## What a held bill is, to this interface
///
/// A cart that was written down, with three states: held, resumed and cancelled. Only a
/// held bill is on the terminal to be acted on. Resuming or cancelling one is terminal —
/// there is no reopening — so every method that changes a bill first checks the state it
/// is in and refuses a move that is not legal from there.
///
/// ## Nothing here sells anything
///
/// Holding, resuming and cancelling all stay inside the three held-bill tables. No order
/// number is allocated, no payment is written, no kitchen slip is raised and no customer
/// record is created. Settlement does all of that, separately, if and when a resumed bill
/// is paid for. See `M007HeldBills` for why held bills are not orders.
///
/// ## Failures
///
/// Every method returns a [Result]. A rule violation — an empty cart, a bill that is
/// gone, a second resume — comes back as a `ValidationFailure` carrying a message written
/// for the cashier. A storage fault comes back as a `LocalStorageFailure`. Nothing throws.
abstract interface class HeldBillRepository {
  /// Writes [draft] as a held bill, with its lines and their options, in one transaction.
  ///
  /// Refuses a draft with nothing on it, because an empty held bill would show up in the
  /// list as something to resume and hand back an empty cart. Refuses a draft whose id has
  /// already been held, so a double tap or two terminals racing write one bill rather than
  /// two.
  Future<Result<HeldBill>> hold(HeldBillDraft draft);

  /// Reads a single held bill whole, its cart rebuilt from the stored lines.
  ///
  /// Returns `null` when no bill with [id] was ever held. A cancelled bill is still
  /// returned — it is kept for audit — so a caller can tell "abandoned" from "never
  /// existed".
  Future<Result<HeldBill?>> findHeldBill(String id);

  /// The bills still on the terminal, oldest first, as list summaries.
  ///
  /// Only bills at `held` are returned; a resumed or cancelled bill has left the list.
  /// Each summary carries the denormalised total and counts, so the list renders without
  /// reading a single line.
  Future<Result<List<HeldBillSummary>>> loadHeldBills();

  /// Takes a held bill back onto the counter, marking it resumed, and returns it whole.
  ///
  /// Refuses a bill that is gone, one already resumed, and one that was cancelled, each
  /// with its own message. The transition is atomic against a second resume, so two
  /// cashiers resuming the same bill cannot both succeed.
  Future<Result<HeldBill>> resume(String id);

  /// Abandons a held bill, marking it cancelled and returning it whole.
  ///
  /// The row and its lines stay, which is what makes an unsettled abandonment auditable.
  /// Refuses a bill that is gone, one already cancelled, and one that was resumed.
  Future<Result<HeldBill>> cancel(String id);
}
