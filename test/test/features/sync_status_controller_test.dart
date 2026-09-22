import 'dart:async';

import 'package:brisko_billing/core/data/sync/sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_status_snapshot.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/cloud_sync/presentation/controllers/sync_status_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A coordinator whose status the test drives directly.
class _FakeCoordinator implements SyncCoordinator {
  final StreamController<SyncStatusSnapshot> _controller =
      StreamController<SyncStatusSnapshot>.broadcast();
  SyncStatusSnapshot _current = const SyncStatusSnapshot.initial();
  int syncNowCalls = 0;

  void emit(SyncStatusSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }

  @override
  Stream<SyncStatusSnapshot> get status => _controller.stream;

  @override
  SyncStatusSnapshot get currentStatus => _current;

  bool _started = false;

  @override
  bool get isStarted => _started;

  @override
  void start() {
    _started = true;
  }

  @override
  Future<void> stop() async {
    _started = false;
  }

  @override
  Future<Result<void>> syncNow() async {
    syncNowCalls++;
    return const Ok<void>(null);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  late _FakeCoordinator coordinator;

  setUp(() {
    coordinator = _FakeCoordinator();
  });

  tearDown(() async {
    await coordinator.dispose();
  });

  SyncStatusController controllerWith({required bool configured}) {
    return SyncStatusController(
      coordinator: coordinator,
      isCloudConfigured: configured,
    );
  }

  test('an unconfigured terminal reports cloud off', () {
    final SyncStatusController controller = controllerWith(configured: false);
    addTearDown(controller.dispose);
    expect(controller.state, SyncIndicatorState.notConfigured);
    expect(controller.label, 'Cloud off');
  });

  test('offline with pending changes shows the count', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    coordinator.emit(
      const SyncStatusSnapshot(
        isOnline: false,
        isSyncing: false,
        pendingCount: 12,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, SyncIndicatorState.offline);
    expect(controller.label, 'Offline — 12 pending');
  });

  test('syncing takes precedence over everything', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    coordinator.emit(
      const SyncStatusSnapshot(
        isOnline: true,
        isSyncing: true,
        pendingCount: 3,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, SyncIndicatorState.syncing);
  });

  test('online with pending changes but no error shows pending', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    coordinator.emit(
      const SyncStatusSnapshot(
        isOnline: true,
        isSyncing: false,
        pendingCount: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, SyncIndicatorState.pendingChanges);
    expect(controller.label, '1 change pending');
  });

  test('a fully clean state reads as synced', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    coordinator.emit(
      SyncStatusSnapshot(
        isOnline: true,
        isSyncing: false,
        pendingCount: 0,
        lastSyncedAt: DateTime.now().toUtc(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, SyncIndicatorState.synced);
    expect(controller.label, 'Synced');
  });

  test('a recorded error reads as failed', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    coordinator.emit(
      const SyncStatusSnapshot(
        isOnline: true,
        isSyncing: false,
        pendingCount: 0,
        lastError: 'server said no',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, SyncIndicatorState.failed);
  });

  test('sync now delegates to the coordinator', () async {
    final SyncStatusController controller = controllerWith(configured: true);
    addTearDown(controller.dispose);

    await controller.syncNow();

    expect(coordinator.syncNowCalls, 1);
  });
}
