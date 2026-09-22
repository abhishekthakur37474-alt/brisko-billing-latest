import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../error/app_failure.dart';
import '../../utils/entity_id.dart';
import '../../utils/result.dart';
import '../connectivity/connectivity_monitor.dart';
import 'outbox_entry.dart';
import 'outbox_store.dart';
import 'sync_coordinator.dart';
import 'sync_endpoint.dart';
import 'sync_metadata_store.dart';
import 'sync_status_snapshot.dart';
import 'syncable_entity.dart';

/// Drives synchronisation between local storage and the cloud.
///
/// ## The write path never comes here
///
/// Billing writes to SQLite and returns. This coordinator runs entirely behind
/// that, on a timer and on the connectivity monitor, so a slow or absent network
/// can never delay a sale. Everything it does is recoverable: a push that fails
/// leaves the work queued, a pull that fails changes nothing locally.
///
/// ## One cycle, push before pull
///
/// A cycle first reconciles the outbox from the local sync state, then drains it to
/// the cloud, then pulls what changed. Push before pull so local work reaches the
/// cloud before anything is merged on top of it.
///
/// ### Reconcile
///
/// Rather than depend on every write site remembering to enqueue, the queue is
/// rebuilt from the truth every write already records: the `syncState` column.
/// Each collection is scanned for records the cloud has not acknowledged — new
/// bills, edits, and soft deletes alike — and any not already queued is enqueued
/// with a snapshot of the row. This is what guarantees no cloud-syncable mutation
/// is ever missed, whichever repository wrote it, without touching a single write
/// path.
///
/// ### Drain
///
/// Queued snapshots are replayed oldest first. A snapshot the cloud accepts marks
/// its local record synced and leaves the queue. A snapshot refused because the
/// link is down stops the drain and stays queued. A snapshot refused by the server
/// records the failure and is retried on a later cycle, never in a tight loop:
/// each entry is attempted at most once per cycle, and the gap between cycles is
/// the backoff.
///
/// ### Pull
///
/// Each collection is asked for records changed since the last successful pull, and
/// the merge into SQLite is last-write-wins by `updatedAt`, protecting any newer
/// local record — including a bill this terminal took and has not yet uploaded.
///
/// ## Conflicts are logged, not lost
///
/// When a pulled record is older than the local copy it is held back rather than
/// applied, and that decision is counted in the merge report so it can be seen
/// rather than silently discarded.
class DefaultSyncCoordinator implements SyncCoordinator {
  DefaultSyncCoordinator({
    required List<SyncEndpointBase> endpoints,
    required this._outbox,
    required this._metadata,
    required this._connectivity,
    this._tableChanges,
    this.retryInterval = const Duration(minutes: 5),
    this.changeDebounce = const Duration(milliseconds: 500),
    this.maxAttempts = 8,
  }) : _endpoints = <String, SyncEndpointBase>{
         for (final SyncEndpointBase endpoint in endpoints)
           endpoint.collection: endpoint,
       };

  final Map<String, SyncEndpointBase> _endpoints;
  final OutboxStore _outbox;
  final SyncMetadataStore _metadata;
  final ConnectivityMonitor _connectivity;

  /// Local-write change feed (`SqliteDatabase.tableChanges`), when wired. A write
  /// to a synced table schedules a debounced [syncNow], so a completed sale is
  /// reconciled and uploaded promptly instead of waiting for the periodic timer.
  /// Left null in tests and local-only builds, where the other triggers apply.
  final Stream<String>? _tableChanges;

  /// The gap between automatic cycles, which is also the backoff between retries
  /// of a queued write the server keeps refusing.
  final Duration retryInterval;

  /// How long to coalesce a burst of local writes before syncing. One checkout
  /// transaction announces several tables at once; a short debounce turns that
  /// burst into a single cycle rather than one cycle per table.
  final Duration changeDebounce;

  /// How many times a single queued write is retried against the server before it
  /// is left alone (still queued and visible) rather than retried forever.
  final int maxAttempts;

  final StreamController<SyncStatusSnapshot> _status =
      StreamController<SyncStatusSnapshot>.broadcast();

  StreamSubscription<bool>? _connectivitySub;
  StreamSubscription<int>? _pendingSub;
  StreamSubscription<String>? _tableChangeSub;
  Timer? _timer;
  Timer? _debounceTimer;

  bool _started = false;
  bool _disposed = false;
  bool _isSyncing = false;

  bool _isOnline = false;
  int _pendingCount = 0;
  DateTime? _lastSyncedAt;
  String? _lastError;
  String? _lastDiagnostic;

  SyncStatusSnapshot _current = const SyncStatusSnapshot.initial();

  @override
  Stream<SyncStatusSnapshot> get status => _status.stream;

  @override
  SyncStatusSnapshot get currentStatus => _current;

  @override
  bool get isStarted => _started;

  @override
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _isOnline = _connectivity.isOnline;

    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      bool online,
    ) {
      _isOnline = online;
      _emit();
      if (online) {
        unawaited(syncNow());
      }
    });

    _pendingSub = _outbox.watchPendingCount().listen((int count) {
      _pendingCount = count;
      _emit();
    });

    _timer = Timer.periodic(retryInterval, (_) {
      if (_isOnline) {
        unawaited(syncNow());
      }
    });

    // A local write to a synced table schedules a debounced cycle, so a settled
    // sale reaches the cloud without waiting for the periodic timer. Filtered to
    // the tables that actually sync — the endpoint keys — so a write to settings,
    // held bills or the outbox itself raises nothing.
    final Stream<String>? tableChanges = _tableChanges;
    if (tableChanges != null) {
      _tableChangeSub = tableChanges
          .where(_endpoints.containsKey)
          .listen(_onSyncedTableChanged);
    }

    unawaited(_primeStatus());
  }

  /// Coalesces a burst of local writes into a single cycle.
  ///
  /// Each relevant change restarts the debounce timer, so the several table
  /// writes of one settlement result in exactly one [syncNow] once the burst
  /// settles. Gated on being online — like the periodic timer — because an
  /// offline write is picked up by the connectivity trigger when the link
  /// returns; nothing is lost in the meantime, it stays queued locally.
  ///
  /// Changes that arrive while a cycle is running are ignored on purpose. A
  /// cycle's own `markSynced` and pull writes announce the very tables it syncs,
  /// so reacting to them would trigger an endless string of no-op cycles. A
  /// genuine write made during a cycle is not lost: it stays pending locally and
  /// is picked up by the next write's trigger or the periodic timer, exactly as
  /// it would have been before this trigger existed.
  void _onSyncedTableChanged(String _) {
    if (_disposed || !_started || _isSyncing) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(changeDebounce, () {
      _debounceTimer = null;
      if (_disposed || !_started || !_isOnline || _isSyncing) {
        return;
      }
      unawaited(syncNow());
    });
  }

  @override
  Future<Result<void>> syncNow() async {
    if (_disposed) {
      return const Err<void>(
        UnexpectedFailure('The sync engine has been shut down.'),
      );
    }
    if (_isSyncing) {
      // A cycle is already running; a second concurrent one would race on the
      // same queue. The running cycle already covers whatever prompted this call.
      return const Ok<void>(null);
    }

    _isSyncing = true;
    _lastError = null;
    _emit();

    try {
      // Rebuild the queue from local truth so nothing pending is missed, then
      // reset attempt counts so manual or periodic syncs retry failed items, and
      // push before pulling anything down on top of it.
      await _reconcile();
      await _outbox.resetAttemptCounts();

      final AppFailure? pushFailure = await _drain();
      if (pushFailure != null) {
        return _finish(pushFailure);
      }

      final AppFailure? pullFailure = await _pull();
      if (pullFailure != null) {
        return _finish(pullFailure);
      }

      // A fully clean cycle: mark it as the last successful sync, which is also
      // the last-backup time shown in Settings.
      final int pending = (await _outbox.pendingCount()).valueOrNull ?? 0;
      _pendingCount = pending;
      if (pending == 0) {
        final DateTime now = DateTime.now().toUtc();
        await _metadata.setLastSyncedAt(now);
        _lastSyncedAt = now;
      }
      return _finish(null);
    } finally {
      _isSyncing = false;
      _emit();
    }
  }

  /// Pauses automatic synchronisation without shutting the engine down.
  ///
  /// Used on sign-out: the terminal is no longer allowed to reach the cloud, so the timer
  /// and the connectivity trigger are cancelled and no further cycle runs. Unlike
  /// [dispose] the status stream stays open, so [start] can bring the engine back when the
  /// operator signs in again. Nothing about the outbox or the local database is touched —
  /// pending work stays queued for the next session.
  Future<void> stop() async {
    if (_disposed || !_started) {
      return;
    }
    _started = false;
    _timer?.cancel();
    _timer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await _pendingSub?.cancel();
    _pendingSub = null;
    await _tableChangeSub?.cancel();
    _tableChangeSub = null;
    _isSyncing = false;
    _isOnline = false;
    _emit();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _debounceTimer?.cancel();
    await _connectivitySub?.cancel();
    await _pendingSub?.cancel();
    await _tableChangeSub?.cancel();
    await _status.close();
  }

  // ------------------------------------------------------------------ phases ---

  /// Enqueues an outbox entry for every unsynced local record not already queued.
  ///
  /// The snapshot is the row as it stands now, including a soft-deleted row's
  /// deleted flag, so replaying it upserts the deletion into the cloud with the
  /// correct timestamp.
  Future<void> _reconcile() async {
    final Set<String> queued = <String>{};
    final List<OutboxEntry> existing =
        (await _outbox.dequeueBatch(limit: 1 << 30)).valueOrNull ??
        const <OutboxEntry>[];
    for (final OutboxEntry entry in existing) {
      queued.add(_key(entry.collection, entry.entityId));
    }

    for (final SyncEndpointBase endpoint in _endpoints.values) {
      final List<SyncableEntity> unsynced =
          (await endpoint.unsynced()).valueOrNull ?? const <SyncableEntity>[];
      for (final SyncableEntity entity in unsynced) {
        final String key = _key(endpoint.collection, entity.id);
        if (queued.contains(key)) {
          continue;
        }
        await _outbox.enqueue(
          OutboxEntry(
            id: EntityId.generate(prefix: 'obx'),
            collection: endpoint.collection,
            entityId: entity.id,
            operation: OutboxOperation.upsert,
            payload: entity.toMap(),
            queuedAt: DateTime.now().toUtc(),
          ),
        );
        queued.add(key);
      }
    }
  }

  /// Replays queued snapshots to the cloud. Returns the failure that stopped the
  /// drain, or `null` when the queue drained or made all the progress it could.
  Future<AppFailure?> _drain() async {
    // Each entry is attempted at most once per cycle, so a batch of entries the
    // server keeps refusing cannot spin the drain in a tight loop; the retry is
    // the next cycle, and the gap between cycles is the backoff.
    final Set<String> attempted = <String>{};

    while (!_disposed) {
      final Result<List<OutboxEntry>> batch = await _outbox.dequeueBatch(
        limit: 50,
        maxAttempts: maxAttempts,
      );
      final List<OutboxEntry>? entries = batch.valueOrNull;
      if (entries == null) {
        return batch.failureOrNull;
      }

      final List<OutboxEntry> fresh = entries
          .where((OutboxEntry e) => !attempted.contains(e.id))
          .toList(growable: false);
      if (fresh.isEmpty) {
        return null;
      }

      for (final OutboxEntry entry in fresh) {
        attempted.add(entry.id);

        // Give up pushing an entry the server has refused too many times, but
        // keep it queued and visible rather than dropping a mutation.
        if (entry.attemptCount >= maxAttempts) {
          continue;
        }

        final SyncEndpointBase? endpoint = _endpoints[entry.collection];
        if (endpoint == null) {
          // A collection this build does not sync. Remove it so it cannot block
          // the queue behind it forever.
          await _outbox.markCompleted(entry.id);
          continue;
        }

        final Result<void> pushed = entry.operation == OutboxOperation.delete
            ? await endpoint.pushDelete(entry.entityId)
            : await endpoint.pushAndMark(entry.payload);

        if (pushed.isOk) {
          await _outbox.markCompleted(entry.id);
          continue;
        }

        final AppFailure failure = pushed.failureOrNull!;
        if (failure is NetworkFailure) {
          // The link is down. Stop; everything stays queued for the next cycle.
          return failure;
        }

        final Map<String, dynamic> diag = <String, dynamic>{
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'operation': 'push',
          'collection': entry.collection,
          'recordId': entry.entityId,
          'outboxId': entry.id,
          'error': failure.message,
          'cause': failure.cause?.toString(),
        };
        _lastDiagnostic = jsonEncode(diag);
        await _writeDiagnosticLog(diag);

        // Server-side refusal: record it and move on. Retried on a later cycle.
        await _outbox.markFailed(entry.id, failure.message);
        _lastError = failure.message;
      }
    }
    return null;
  }

  /// Pulls each collection's changes and advances the high-water mark.
  Future<AppFailure?> _pull() async {
    final DateTime? since = (await _metadata.pullHighWaterMark()).valueOrNull;
    DateTime? newest = since;

    for (final SyncEndpointBase endpoint in _endpoints.values) {
      final Result<PullOutcome> result = await endpoint.pull(since);
      final PullOutcome? outcome = result.valueOrNull;
      if (outcome == null) {
        final AppFailure failure = result.failureOrNull!;
        
        final Map<String, dynamic> diag = <String, dynamic>{
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'operation': 'pull',
          'collection': endpoint.collection,
          'error': failure.message,
          'cause': failure.cause?.toString(),
        };
        _lastDiagnostic = jsonEncode(diag);
        await _writeDiagnosticLog(diag);

        // A network failure means offline; a remote failure means the server
        // refused. Either way, stop pulling and keep what we have.
        return failure;
      }
      final DateTime? collectionNewest = outcome.newestUpdatedAt;
      if (collectionNewest != null &&
          (newest == null || collectionNewest.isAfter(newest))) {
        newest = collectionNewest;
      }
    }

    if (newest != null && (since == null || newest.isAfter(since))) {
      await _metadata.setPullHighWaterMark(newest);
    }
    return null;
  }

  // ------------------------------------------------------------------ status ---

  Future<void> _primeStatus() async {
    _lastSyncedAt = (await _metadata.lastSyncedAt()).valueOrNull;
    _pendingCount = (await _outbox.pendingCount()).valueOrNull ?? 0;
    _isOnline = _connectivity.isOnline;
    _emit();
    if (_isOnline) {
      unawaited(syncNow());
    }
  }

  Result<void> _finish(AppFailure? failure) {
    if (failure != null && failure is! NetworkFailure) {
      _lastError = failure.message;
    }
    if (failure == null) {
      _lastError = null;
      _lastDiagnostic = null;
    }
    return failure == null ? const Ok<void>(null) : Err<void>(failure);
  }

  void _emit() {
    if (_disposed || _status.isClosed) {
      return;
    }
    _current = SyncStatusSnapshot(
      isOnline: _isOnline,
      isSyncing: _isSyncing,
      pendingCount: _pendingCount,
      lastSyncedAt: _lastSyncedAt,
      lastError: _lastError,
      lastDiagnostic: _lastDiagnostic,
    );
    _status.add(_current);
  }

  Future<void> _writeDiagnosticLog(Map<String, dynamic> info) async {
    try {
      final String dbPath = await getDatabasesPath();
      final File logFile = File(p.join(dbPath, 'sync_diagnostics.log'));
      final String jsonStr = jsonEncode(info);
      await logFile.writeAsString('$jsonStr\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Swallow error during diagnostic logging
    }
  }

  static String _key(String collection, String entityId) =>
      '$collection|$entityId';
}
