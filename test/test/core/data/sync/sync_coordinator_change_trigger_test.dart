import 'dart:async';

import 'package:brisko_billing/app/sync/sync_endpoints.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_local_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/default_sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_status_snapshot.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_cloud.dart';
import '../../../helpers/fake_connectivity_monitor.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/test_database.dart';

/// The local-write trigger added to [DefaultSyncCoordinator]: a write to a synced
/// table schedules one debounced cycle, so a completed sale reaches the cloud
/// without waiting for the periodic timer — and the trigger is inert once the
/// coordinator is stopped or disposed, and deaf to tables that do not sync.
///
/// These are deliberately time-based: the whole point is the debounce. A short
/// debounce keeps them fast; the waits are generous multiples of it so timing
/// jitter on a busy machine does not make them flaky.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late FakeCloud cloud;
  late FakeConnectivityMonitor connectivity;
  late SqliteOutboxStore outbox;
  late SqliteSyncMetadataStore metadata;
  late SqliteLocalStore<Customer> customers;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    cloud = FakeCloud();
    connectivity = FakeConnectivityMonitor(online: true);
    outbox = SqliteOutboxStore(database: database);
    metadata = SqliteSyncMetadataStore(database: database);
    customers = SqliteLocalStore<Customer>(
      database: database,
      table: SqliteTables.customers,
      fromRow: Customer.fromRow,
    );
  });

  tearDown(() async {
    await connectivity.dispose();
    await outbox.dispose();
    await database.close();
  });

  /// Builds a coordinator wired to the database change feed, with a short
  /// debounce so the tests stay fast. Disposed automatically.
  DefaultSyncCoordinator buildCoordinator({
    Stream<String>? tableChanges,
    Duration changeDebounce = const Duration(milliseconds: 40),
    Duration retryInterval = const Duration(minutes: 5),
  }) {
    final DefaultSyncCoordinator coordinator = DefaultSyncCoordinator(
      endpoints: buildSyncEndpoints(database, FakeRemoteStoreFactory(cloud), outbox),
      outbox: outbox,
      metadata: metadata,
      connectivity: connectivity,
      tableChanges: tableChanges ?? database.tableChanges,
      changeDebounce: changeDebounce,
      retryInterval: retryInterval,
    );
    addTearDown(coordinator.dispose);
    return coordinator;
  }

  test(
    'a write to a synced table triggers a sync cycle after the debounce',
    () async {
      final DefaultSyncCoordinator coordinator = buildCoordinator();
      coordinator.start();
      // Let the start-up cycle settle before the write under test.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final Customer customer = Fixtures.customer(phone: '9500000001');
      await customers.save(customer);

      // Nothing is uploaded synchronously; the cycle waits for the debounce.
      expect(cloud.row(SqliteTables.customers, customer.id), isNull);

      // After the debounce, the write has reconciled and uploaded on its own.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
      expect((await outbox.pendingCount()).valueOrNull, 0);
    },
  );

  test('several writes close together cause only one sync cycle', () async {
    final DefaultSyncCoordinator coordinator = buildCoordinator(
      changeDebounce: const Duration(milliseconds: 120),
    );
    final _CycleCounter counter = _CycleCounter(coordinator);
    addTearDown(counter.dispose);

    coordinator.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // Ignore the start-up cycle; count only what the burst below causes.
    counter.reset();

    // A burst standing in for a single settlement touching several tables.
    await customers.save(Fixtures.customer(phone: '9500000101'));
    await customers.save(Fixtures.customer(phone: '9500000102'));
    await customers.save(Fixtures.customer(phone: '9500000103'));

    // Well past the debounce and the one cycle it schedules.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(counter.cycles, 1);
    // That single cycle still uploaded every queued row.
    expect(cloud.count(SqliteTables.customers), 3);
  });

  test('a change to a table that does not sync triggers nothing', () async {
    final DefaultSyncCoordinator coordinator = buildCoordinator();
    final _CycleCounter counter = _CycleCounter(coordinator);
    addTearDown(counter.dispose);

    coordinator.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    counter.reset();

    // None of these tables is a sync endpoint, so none should schedule a cycle.
    database.notifyTableChanged(SqliteTables.settings);
    database.notifyTableChanged(SqliteTables.heldBills);
    database.notifyTableChanged(SqliteTables.outbox);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(counter.cycles, 0);
    expect(cloud.count(SqliteTables.customers), 0);
  });

  group('existing triggers still work with the change feed wired', () {
    test('a manual syncNow still uploads', () async {
      final DefaultSyncCoordinator coordinator = buildCoordinator();
      // Not started: no automatic triggers at all, only the manual call.
      final Customer customer = Fixtures.customer(phone: '9500000201');
      await customers.save(customer);

      final Result<void> result = await coordinator.syncNow();

      expect(result.isOk, isTrue);
      expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
    });

    test('connectivity returning still triggers a sync', () async {
      connectivity = FakeConnectivityMonitor(online: false);
      final DefaultSyncCoordinator coordinator = buildCoordinator();
      coordinator.start();

      final Customer customer = Fixtures.customer(phone: '9500000202');
      await customers.save(customer);

      // Offline, the change trigger is correctly gated: nothing uploads yet.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(cloud.row(SqliteTables.customers, customer.id), isNull);

      // The link returns: the connectivity trigger drains the queue.
      connectivity.setOnline(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
    });

    test('the periodic timer still triggers a sync on its own', () async {
      // No change feed, so only the periodic timer can drive this cycle.
      final DefaultSyncCoordinator coordinator = buildCoordinator(
        tableChanges: const Stream<String>.empty(),
        retryInterval: const Duration(milliseconds: 60),
      );
      coordinator.start();
      // Let the start-up cycle pass, then create work with no trigger of its own.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final Customer customer = Fixtures.customer(phone: '9500000203');
      await customers.save(customer);

      // The next timer tick picks it up.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
    });
  });

  group('no sync after the coordinator is shut down', () {
    test('a write after stop() schedules nothing', () async {
      final DefaultSyncCoordinator coordinator = buildCoordinator();
      final _CycleCounter counter = _CycleCounter(coordinator);
      addTearDown(counter.dispose);

      coordinator.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await coordinator.stop();
      counter.reset();

      final Customer customer = Fixtures.customer(phone: '9500000301');
      await customers.save(customer);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(counter.cycles, 0);
      expect(cloud.row(SqliteTables.customers, customer.id), isNull);
    });

    test('a write after dispose() schedules nothing', () async {
      final DefaultSyncCoordinator coordinator = buildCoordinator();
      coordinator.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await coordinator.dispose();

      final Customer customer = Fixtures.customer(phone: '9500000302');
      await customers.save(customer);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(cloud.row(SqliteTables.customers, customer.id), isNull);
    });
  });
}

/// Counts sync cycles by watching the status stream for the rising edge of
/// `isSyncing` — one rising edge per cycle a coordinator actually starts.
class _CycleCounter {
  _CycleCounter(SyncCoordinator coordinator) {
    _subscription = coordinator.status.listen((SyncStatusSnapshot snapshot) {
      if (snapshot.isSyncing && !_wasSyncing) {
        _cycles++;
      }
      _wasSyncing = snapshot.isSyncing;
    });
  }

  late final StreamSubscription<SyncStatusSnapshot> _subscription;
  bool _wasSyncing = false;
  int _cycles = 0;

  int get cycles => _cycles;

  void reset() => _cycles = 0;

  Future<void> dispose() => _subscription.cancel();
}
