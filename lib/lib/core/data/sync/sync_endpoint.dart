import '../../utils/result.dart';
import '../local_store.dart';
import '../remote_store.dart';
import 'remote_merge_report.dart';
import 'syncable_entity.dart';

/// What a pull of one collection produced.
class PullOutcome {
  const PullOutcome({required this.report, required this.newestUpdatedAt});

  const PullOutcome.empty()
    : report = const RemoteMergeReport.empty(),
      newestUpdatedAt = null;

  final RemoteMergeReport report;

  /// The newest `updatedAt` among the downloaded records, or `null` when none
  /// were returned. Feeds the pull high-water mark.
  final DateTime? newestUpdatedAt;
}

/// Type-erased view of a syncable collection, so the coordinator can iterate over
/// collections of different entity types uniformly.
///
/// A `RemoteStore` is typed to one entity; a coordinator that pushed bills, menu
/// items and customers would otherwise need to name each type. This interface
/// hides the type parameter behind operations phrased in terms the coordinator
/// actually uses — replay a queued snapshot, mark it acknowledged, pull what
/// changed — while [SyncEndpoint] keeps the concrete type internally.
abstract interface class SyncEndpointBase {
  /// The collection name, matching the outbox `collection` and the cloud table.
  String get collection;

  /// Local records the cloud has not acknowledged, including soft-deleted ones,
  /// which are pushed as ordinary rows carrying their deleted flag.
  Future<Result<List<SyncableEntity>>> unsynced();

  /// Replays one queued snapshot to the cloud and, on success, marks the local
  /// record acknowledged if it has not changed since.
  Future<Result<void>> pushAndMark(Map<String, dynamic> payload);

  /// Propagates a bare deletion by id, for a queued delete operation.
  Future<Result<void>> pushDelete(String id);

  /// Downloads and merges everything changed after [since].
  Future<Result<PullOutcome>> pull(DateTime? since);
}

/// Binds one entity type's local store and remote store into a [SyncEndpointBase].
///
/// The entity's own `toMap`/[fromRow] is the wire format on both sides, so there is
/// no separate transfer object and no mapping to keep in step: what is written to
/// SQLite is what is sent to the cloud, and what is pulled is rebuilt the same way
/// a SQLite row is.
class SyncEndpoint<T extends SyncableEntity> implements SyncEndpointBase {
  const SyncEndpoint({
    required this.collection,
    required this.fromRow,
    required this._local,
    required this._remote,
  });

  @override
  final String collection;

  final LocalStore<T> _local;

  final RemoteStore<T> _remote;

  /// Rebuilds an entity from a stored/queued/downloaded row.
  final T Function(Map<String, Object?> row) fromRow;

  @override
  Future<Result<List<SyncableEntity>>> unsynced() async {
    final Result<List<T>> result = await _local.findUnsynced();
    return result.map(
      (List<T> list) => list.cast<SyncableEntity>().toList(growable: false),
    );
  }

  @override
  Future<Result<void>> pushAndMark(Map<String, dynamic> payload) async {
    final T entity = fromRow(payload);
    final Result<void> pushed = await _remote.push(entity);
    if (pushed.isErr) {
      return pushed;
    }
    // Guarded on the pushed version, so an edit made while the push was in flight
    // stays pending and is uploaded next cycle rather than being marked synced.
    return _local.markSynced(entity.id, entity.updatedAt);
  }

  @override
  Future<Result<void>> pushDelete(String id) => _remote.pushDelete(id);

  @override
  Future<Result<PullOutcome>> pull(DateTime? since) async {
    final Result<List<T>> pulled = await _remote.pullChangedSince(since);
    final List<T>? rows = pulled.valueOrNull;
    if (rows == null) {
      return Err<PullOutcome>(pulled.failureOrNull!);
    }

    final Result<RemoteMergeReport> merged = await _local.applyRemoteChanges(
      rows,
    );
    final RemoteMergeReport? report = merged.valueOrNull;
    if (report == null) {
      return Err<PullOutcome>(merged.failureOrNull!);
    }

    DateTime? newest;
    for (final T entity in rows) {
      if (newest == null || entity.updatedAt.isAfter(newest)) {
        newest = entity.updatedAt;
      }
    }
    return Ok<PullOutcome>(
      PullOutcome(report: report, newestUpdatedAt: newest),
    );
  }
}
