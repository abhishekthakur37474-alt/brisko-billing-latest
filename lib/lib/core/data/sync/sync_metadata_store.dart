import '../../utils/result.dart';

/// Durable bookmarks the synchronisation engine keeps between runs.
///
/// Deliberately narrow. The engine needs three facts to survive a restart, and
/// nothing more: how far the last pull got, when the last full sync succeeded, and
/// whether this terminal has finished its one-time bootstrap. Keeping them behind
/// this interface means the storage detail stays in the data layer and the
/// coordinator can be tested against an in-memory fake.
abstract interface class SyncMetadataStore {
  /// The `updatedAt` of the newest record pulled in the last successful pull, so
  /// the next pull can ask the cloud only for what changed after it. `null` before
  /// the first pull, which requests everything.
  Future<Result<DateTime?>> pullHighWaterMark();

  Future<Result<void>> setPullHighWaterMark(DateTime value);

  /// When the last push-then-pull cycle completed with nothing left pending. Shown
  /// in Settings as "synced" and used as the last-backup time.
  Future<Result<DateTime?>> lastSyncedAt();

  Future<Result<void>> setLastSyncedAt(DateTime value);

  /// True once the terminal has completed its initial bootstrap: either it
  /// restored from the cloud, or it decided its existing local data is the
  /// starting point. Guards against a restore ever running over a database that is
  /// already in use.
  Future<Result<bool>> isBootstrapped();

  Future<Result<void>> markBootstrapped();
}
