import 'dart:async';

import '../../core/data/connectivity/polling_connectivity_monitor.dart';
import '../../core/data/sync/default_sync_coordinator.dart';
import '../../core/data/sync/initial_sync_service.dart';
import '../../features/auth/domain/services/manager_auth_service.dart';

/// Turns cloud synchronisation on and off in step with the sign-in state.
///
/// Authentication and synchronisation are separate concerns, joined only here: the
/// [AuthController] decides *whether* the terminal is signed in, and this decides what
/// that means for the sync engine. Keeping the join behind one small seam is what lets the
/// auth layer stay free of the coordinator, the connectivity monitor and the one-time
/// restore, and lets those stay free of anything to do with a login screen.
///
/// It is deliberately an interface. The real wiring drives the actual engine; a test
/// substitutes a recording double so signing in and out can be checked without a timer, a
/// network probe or a backend.
abstract interface class CloudSyncActivation {
  /// Starts synchronising: connectivity polling, the push/pull coordinator, and the
  /// one-time restore for a fresh terminal. Idempotent — calling it while already active
  /// does nothing, so a second sign-in in the same run cannot start two engines.
  Future<void> enable();

  /// Stops synchronising until the next [enable]. The outbox and local database are left
  /// exactly as they are, so nothing queued is lost. Idempotent.
  Future<void> disable();
}

/// The production [CloudSyncActivation] over the real sync engine.
///
/// Owns nothing it did not receive: the connectivity monitor, coordinator and restore
/// service are all built and disposed by the bootstrap. This only decides when they run.
class DefaultCloudSyncActivation implements CloudSyncActivation {
  DefaultCloudSyncActivation({
    required PollingConnectivityMonitor connectivity,
    required DefaultSyncCoordinator coordinator,
    required InitialSyncService initialSync,
    ManagerAuthService? managerAuth,
  }) : _connectivity = connectivity,
       _coordinator = coordinator,
       _initialSync = initialSync,
       _managerAuth = managerAuth;

  final PollingConnectivityMonitor _connectivity;
  final DefaultSyncCoordinator _coordinator;
  final InitialSyncService _initialSync;
  final ManagerAuthService? _managerAuth;

  bool _enabled = false;

  /// True once the sync engine has been switched on for the current session.
  bool get isEnabled => _enabled;

  @override
  Future<void> enable() async {
    if (_enabled) {
      return;
    }
    _enabled = true;

    // Both starts are individually idempotent, so re-enabling after a disable simply
    // resubscribes the coordinator to the connectivity monitor that kept running.
    _connectivity.start();
    _coordinator.start();

    // The one-time restore/bootstrap, in the background so a slow or absent network never
    // blocks the sign-in from completing. It refuses to run over a database that already
    // holds bills, so it can only ever seed a genuinely empty terminal.
    unawaited(_initialSync.run());

    // Manager password is a singleton RTDB node, not an outbox collection. Pull
    // it on enable so a password set on another terminal is cached before the
    // first cancellation.
    final ManagerAuthService? managerAuth = _managerAuth;
    if (managerAuth != null) {
      unawaited(managerAuth.syncFromRtdb());
    }
  }

  @override
  Future<void> disable() async {
    if (!_enabled) {
      return;
    }
    _enabled = false;
    // Leave the connectivity monitor polling — it is cheap and holds no session — and just
    // stop the coordinator, so no cycle runs while signed out and nothing queued is
    // touched.
    await _coordinator.stop();
  }
}
