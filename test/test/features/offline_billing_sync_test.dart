import 'package:brisko_billing/app/sync/sync_endpoints.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/default_sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_endpoint.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_cloud.dart';
import '../helpers/fake_connectivity_monitor.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// Proves the offline-first contract end to end: a sale is settled with the cloud
/// unreachable, nothing about it is lost, and when the link returns the whole bill
/// — order, lines, payment and kitchen slip — reaches the cloud exactly once.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late FakeCloud cloud;
  late FakeConnectivityMonitor connectivity;
  late SqliteOutboxStore outbox;
  late SqliteSyncMetadataStore metadata;
  late DefaultSyncCoordinator coordinator;
  late SeededSales sales;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    // The cloud is down while the bill is taken.
    cloud = FakeCloud(mode: FakeCloudMode.offline);
    connectivity = FakeConnectivityMonitor(online: false);
    outbox = SqliteOutboxStore(database: database);
    metadata = SqliteSyncMetadataStore(database: database);
    final List<SyncEndpointBase> endpoints = buildSyncEndpoints(
      database,
      FakeRemoteStoreFactory(cloud),
      outbox,
    );
    coordinator = DefaultSyncCoordinator(
      endpoints: endpoints,
      outbox: outbox,
      metadata: metadata,
      connectivity: connectivity,
    );
    sales = SeededSales(database);
  });

  tearDown(() async {
    await coordinator.dispose();
    await connectivity.dispose();
    await outbox.dispose();
    await database.close();
  });

  Future<int> countRows(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS c FROM $table',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  test('a sale settles with the cloud unreachable and is not lost', () async {
    // The whole sale is written while offline. Nothing here awaits the network.
    final String customerId = await sales.customer(phone: '9000000123');
    final String orderId = await sales.bill(
      orderNumber: '20260601-0001',
      at: DateTime.utc(2026, 6, 1, 12),
      customerId: customerId,
      kotNumber: 'K20260601-0001',
    );

    // The sale is on disk: the offline outage did not block it.
    expect(await countRows(SqliteTables.orders), 1);
    expect(await countRows(SqliteTables.payments), 1);
    expect(await countRows(SqliteTables.kotRecords), 1);

    // A sync attempt while offline queues the work and reports offline, losing
    // nothing.
    final Result<void> offlineResult = await coordinator.syncNow();
    expect(offlineResult.isErr, isTrue);
    expect((await outbox.pendingCount()).valueOrNull, greaterThan(0));

    // The link returns.
    cloud.mode = FakeCloudMode.online;
    connectivity.setOnline(true);
    final Result<void> onlineResult = await coordinator.syncNow();

    // The entire bill reached the cloud, once each.
    expect(onlineResult.isOk, isTrue);
    expect(cloud.count(SqliteTables.orders), 1);
    expect(cloud.count(SqliteTables.orderItems), 1);
    expect(cloud.count(SqliteTables.payments), 1);
    expect(cloud.count(SqliteTables.kotRecords), 1);
    expect(cloud.count(SqliteTables.customers), 1);
    expect(cloud.row(SqliteTables.orders, orderId), isNotNull);

    // And the queue is empty: nothing pending, nothing duplicated.
    expect((await outbox.pendingCount()).valueOrNull, 0);
  });

  test('re-syncing does not upload the bill a second time', () async {
    await sales.bill(
      orderNumber: '20260601-0002',
      at: DateTime.utc(2026, 6, 1, 13),
    );
    cloud.mode = FakeCloudMode.online;

    await coordinator.syncNow();
    final int afterFirst = cloud.pushCount;
    await coordinator.syncNow();

    // The second cycle has nothing to push: stable ids and the synced flag mean
    // no row is re-uploaded.
    expect(cloud.pushCount, afterFirst);
    expect(cloud.count(SqliteTables.orders), 1);
  });
}
