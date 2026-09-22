import '../../utils/result.dart';
import 'outbox_entry.dart';

/// Durable queue of writes waiting to reach the cloud.
///
/// Must survive application restarts and power loss. If the terminal is switched
/// off mid-shift with fifty unsynced bills, all fifty are still queued when it
/// comes back up.
abstract interface class OutboxStore {
  /// Appends a pending write.
  Future<Result<void>> enqueue(OutboxEntry entry);

  /// Oldest pending entries first, capped at [limit], so the replay order matches
  /// the order the cashier performed the work. Excludes entries that have exceeded
  /// [maxAttempts].
  Future<Result<List<OutboxEntry>>> dequeueBatch({int limit = 50, int maxAttempts = 8});

  /// Removes an entry after the cloud has accepted it.
  Future<Result<void>> markCompleted(String entryId);

  /// Records a failed attempt so the entry can be retried with backoff.
  Future<Result<void>> markFailed(String entryId, String error);

  /// Resets the attempt count of all pending entries to 0 so they can be retried.
  Future<Result<void>> resetAttemptCounts();

  /// Empties the queue. Used when operational data is cleared so leftover
  /// snapshots cannot be uploaded after the rows they describe are gone.
  Future<Result<void>> clearAll();

  /// How many writes are still waiting. Drives the sync indicator in the UI.
  Future<Result<int>> pendingCount();

  /// Emits the pending count whenever it changes.
  Stream<int> watchPendingCount();
}
