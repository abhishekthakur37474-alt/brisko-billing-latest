import '../utils/result.dart';
import 'sync/remote_merge_report.dart';
import 'sync/syncable_entity.dart';

/// On-device persistence for one collection of entities.
///
/// This is the write path the billing module talks to, directly or through a
/// repository. It must succeed with no internet connection, which is why it is a
/// separate contract from `RemoteStore` rather than a cache in front of it.
///
/// The concrete implementation is chosen later. Nothing above this interface
/// depends on which local database is used.
abstract interface class LocalStore<T extends SyncableEntity> {
  /// Returns the entity, or `null` when absent. Soft-deleted records are not
  /// returned.
  Future<Result<T?>> findById(String id);

  /// All live records. Soft-deleted records are excluded.
  Future<Result<List<T>>> findAll();

  /// Inserts or replaces a record.
  Future<Result<void>> save(T entity);

  /// Inserts or replaces many records in one transaction. Used when pulling
  /// changes down from the cloud.
  Future<Result<void>> saveAll(Iterable<T> entities);

  /// Marks a record deleted without physically removing it, so the deletion can
  /// still be pushed to the cloud.
  Future<Result<void>> softDelete(String id);

  /// Records that the cloud has not acknowledged yet.
  Future<Result<List<T>>> findUnsynced();

  /// Marks the record acknowledged by the cloud, but only if it has not changed
  /// since [version] was pushed.
  ///
  /// [version] is the `updatedAt` value that was uploaded. If the cashier edited
  /// the record again while the push was in flight, the stored `updatedAt` no
  /// longer matches and the record is left pending, so the newer edit is not lost
  /// by being marked synced. This is what makes the push half safe on a single
  /// SQLite connection without locking the record for the duration of a network
  /// call.
  Future<Result<void>> markSynced(String id, DateTime version);

  /// Merges records pulled from the cloud into local storage.
  ///
  /// The download half of synchronisation. Each record is written only when it is
  /// strictly newer than the local copy by `updatedAt`, or when there is no local
  /// copy at all; an older or equal cloud record is held back so a newer local
  /// bill is never overwritten. Soft deletes ride the same path, because a deleted
  /// record still carries an `updatedAt` and an `isDeleted` flag.
  ///
  /// Merged records are stored as synced and never re-enqueued, so a download does
  /// not turn into an upload of the same data.
  Future<Result<RemoteMergeReport>> applyRemoteChanges(Iterable<T> entities);

  /// Emits the full live record set whenever it changes, so the UI can rebuild
  /// without polling.
  Stream<List<T>> watchAll();
}
