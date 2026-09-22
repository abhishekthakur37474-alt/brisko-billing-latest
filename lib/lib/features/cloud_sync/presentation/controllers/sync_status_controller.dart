import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/data/sync/sync_coordinator.dart';
import '../../../../core/data/sync/sync_status_snapshot.dart';

/// The single state a sync indicator can be in, chosen so the UI never has to
/// reason about the raw combination of online/syncing/pending/error.
enum SyncIndicatorState {
  /// No cloud backend is set up on this terminal.
  notConfigured,

  /// Configured but the link is down. Local billing is unaffected.
  offline,

  /// A push/pull cycle is running.
  syncing,

  /// The last cycle hit a server-side problem worth surfacing.
  failed,

  /// Everything works and there are local changes still to upload.
  pendingChanges,

  /// Everything is uploaded and acknowledged.
  synced,
}

/// Presents the coordinator's status to the shell and the Settings screen.
///
/// A thin adapter over [SyncCoordinator]: it listens to the status stream, folds
/// the raw snapshot into a single [SyncIndicatorState] with a human label, and
/// exposes the manual "sync now" action. It holds no sync logic of its own, so the
/// engine stays testable without a widget and the widgets stay free of the engine.
///
/// Nothing here can block billing. The worst a widget reading this can do is show a
/// stale label for a moment; it never gates a screen.
class SyncStatusController extends ChangeNotifier {
  SyncStatusController({
    required SyncCoordinator coordinator,
    required this.isCloudConfigured,
  }) : _coordinator = coordinator,
       _snapshot = coordinator.currentStatus {
    _subscription = coordinator.status.listen((SyncStatusSnapshot snapshot) {
      _snapshot = snapshot;
      _safeNotify();
    });
  }

  final SyncCoordinator _coordinator;

  /// Whether a Firebase backend was configured at start-up.
  final bool isCloudConfigured;

  SyncStatusSnapshot _snapshot;
  StreamSubscription<SyncStatusSnapshot>? _subscription;
  bool _isManualSyncing = false;
  bool _isDisposed = false;

  bool get isOnline => _snapshot.isOnline;

  bool get isSyncing => _snapshot.isSyncing || _isManualSyncing;

  int get pendingCount => _snapshot.pendingCount;

  DateTime? get lastSyncedAt => _snapshot.lastSyncedAt;

  String? get lastError => _snapshot.lastError;

  String? get lastDiagnostic => _snapshot.lastDiagnostic;

  /// The single state the indicator renders.
  SyncIndicatorState get state {
    if (!isCloudConfigured) {
      return SyncIndicatorState.notConfigured;
    }
    if (isSyncing) {
      return SyncIndicatorState.syncing;
    }
    if (!isOnline) {
      return SyncIndicatorState.offline;
    }
    if (lastError != null) {
      return SyncIndicatorState.failed;
    }
    if (pendingCount > 0) {
      return SyncIndicatorState.pendingChanges;
    }
    return SyncIndicatorState.synced;
  }

  /// Short label for the indicator chip.
  String get label => switch (state) {
    SyncIndicatorState.notConfigured => 'Cloud off',
    SyncIndicatorState.offline =>
      pendingCount > 0 ? 'Offline — $pendingCount pending' : 'Offline',
    SyncIndicatorState.syncing => 'Syncing…',
    SyncIndicatorState.failed => 'Sync failed',
    SyncIndicatorState.pendingChanges =>
      '$pendingCount ${pendingCount == 1 ? 'change' : 'changes'} pending',
    SyncIndicatorState.synced => 'Synced',
  };

  /// Longer, sentence-form description for the Settings screen.
  String get detail => switch (state) {
    SyncIndicatorState.notConfigured =>
      'This terminal is not connected to the cloud. All data is saved locally.',
    SyncIndicatorState.offline =>
      pendingCount > 0
          ? 'Offline. $pendingCount ${pendingCount == 1 ? 'change is' : 'changes are'} waiting to upload.'
          : 'Offline. Everything is saved on this device.',
    SyncIndicatorState.syncing => 'Syncing with the cloud…',
    SyncIndicatorState.failed =>
      lastError ?? 'The last sync did not complete. It will be retried.',
    SyncIndicatorState.pendingChanges =>
      '$pendingCount ${pendingCount == 1 ? 'change is' : 'changes are'} waiting to upload.',
    SyncIndicatorState.synced => _syncedDetail(),
  };

  /// Runs a manual sync. Reports offline clearly rather than pretending; never
  /// required for normal operation.
  Future<void> syncNow() async {
    if (_isManualSyncing) {
      return;
    }
    _isManualSyncing = true;
    _safeNotify();
    try {
      await _coordinator.syncNow();
    } finally {
      _isManualSyncing = false;
      _safeNotify();
    }
  }

  String _syncedDetail() {
    final DateTime? at = lastSyncedAt;
    if (at == null) {
      return 'Everything is up to date.';
    }
    return 'Synced ${_relative(at)}.';
  }

  /// A rough, friendly relative time. Precision is not the point here; a cashier
  /// wants to know "recently" versus "a while ago", not a timestamp.
  static String _relative(DateTime at) {
    final Duration ago = DateTime.now().toUtc().difference(at.toUtc());
    if (ago.inSeconds < 60) {
      return 'just now';
    }
    if (ago.inMinutes < 60) {
      final int m = ago.inMinutes;
      return '$m ${m == 1 ? 'minute' : 'minutes'} ago';
    }
    if (ago.inHours < 24) {
      final int h = ago.inHours;
      return '$h ${h == 1 ? 'hour' : 'hours'} ago';
    }
    final int d = ago.inDays;
    return '$d ${d == 1 ? 'day' : 'days'} ago';
  }

  void _safeNotify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}
