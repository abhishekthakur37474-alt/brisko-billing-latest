import 'package:brisko_billing/app/sync/sync_endpoints.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_local_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/default_sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/outbox_entry.dart';
import 'package:brisko_billing/core/data/sync/sync_endpoint.dart';
import 'package:brisko_billing/core/data/sync/sync_state.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:brisko_billing/features/expenses/domain/models/expense.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_cloud.dart';
import '../../../helpers/fake_connectivity_monitor.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late FakeCloud cloud;
  late FakeConnectivityMonitor connectivity;
  late SqliteOutboxStore outbox;
  late SqliteSyncMetadataStore metadata;
  late DefaultSyncCoordinator coordinator;
  late SqliteLocalStore<Customer> customers;
  late SqliteLocalStore<Order> orders;
  late SqliteLocalStore<Expense> expenses;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    cloud = FakeCloud();
    connectivity = FakeConnectivityMonitor(online: true);
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

    customers = SqliteLocalStore<Customer>(
      database: database,
      table: SqliteTables.customers,
      fromRow: Customer.fromRow,
    );
    orders = SqliteLocalStore<Order>(
      database: database,
      table: SqliteTables.orders,
      fromRow: Order.fromRow,
    );
    expenses = SqliteLocalStore<Expense>(
      database: database,
      table: SqliteTables.expenses,
      fromRow: Expense.fromRow,
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await connectivity.dispose();
    await outbox.dispose();
    await database.close();
  });

  Future<SyncState?> storedState(String table, String id) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      table,
      columns: <String>[SyncColumns.syncState, SyncColumns.isDeleted],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return SyncState.values.firstWhere(
      (SyncState s) => s.name == rows.first[SyncColumns.syncState],
    );
  }

  group('offline behaviour', () {
    test('an offline mutation is queued to the outbox, not lost', () async {
      cloud.mode = FakeCloudMode.offline;
      final Customer customer = Fixtures.customer(phone: '9000000001');
      await customers.save(customer);

      final Result<void> result = await coordinator.syncNow();

      // Offline is reported as a network failure, not a silent success.
      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<NetworkFailure>());

      // The change is durably queued for later, and the record is still pending.
      final List<OutboxEntry> queued =
          (await outbox.dequeueBatch()).valueOrNull!;
      expect(
        queued.where((OutboxEntry e) => e.entityId == customer.id),
        hasLength(1),
      );
      expect(
        await storedState(SqliteTables.customers, customer.id),
        SyncState.pending,
      );
    });

    test('an offline sync does not block or lose local data', () async {
      cloud.mode = FakeCloudMode.offline;
      await customers.save(Fixtures.customer(phone: '9000000002'));
      await customers.save(Fixtures.customer(phone: '9000000003'));

      await coordinator.syncNow();

      // Both local records survive untouched.
      expect((await customers.findAll()).valueOrNull, hasLength(2));
      expect((await outbox.pendingCount()).valueOrNull, 2);
    });
  });

  group('upload', () {
    test(
      'a successful upload clears the outbox and marks the record synced',
      () async {
        final Customer customer = Fixtures.customer(phone: '9100000001');
        await customers.save(customer);

        final Result<void> result = await coordinator.syncNow();

        expect(result.isOk, isTrue);
        expect((await outbox.pendingCount()).valueOrNull, 0);
        expect(
          await storedState(SqliteTables.customers, customer.id),
          SyncState.synced,
        );
        expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
      },
    );

    test('an expense is uploaded to RTDB with the rest of operational data', () async {
      final Expense expense = Expense(
        id: 'exp-sync-1',
        name: 'Vegetables',
        amount: Money.parse('50.00'),
        createdAt: DateTime.utc(2026, 9, 22, 10),
        updatedAt: DateTime.utc(2026, 9, 22, 10),
      );
      await expenses.save(expense);

      final Result<void> result = await coordinator.syncNow();

      expect(result.isOk, isTrue);
      expect(
        await storedState(SqliteTables.expenses, expense.id),
        SyncState.synced,
      );
      expect(cloud.row(SqliteTables.expenses, expense.id), isNotNull);
      expect(
        cloud.row(SqliteTables.expenses, expense.id)!['name'],
        'Vegetables',
      );
    });

    test(
      'a failed upload stays queued and is retried on the next cycle',
      () async {
        cloud.mode = FakeCloudMode.unavailable;
        final Customer customer = Fixtures.customer(phone: '9100000002');
        await customers.save(customer);

        final Result<void> failed = await coordinator.syncNow();
        expect(failed.isErr, isTrue);
        expect(failed.failureOrNull, isA<RemoteFailure>());

        // Kept, with the attempt recorded — never discarded.
        final OutboxEntry entry =
            (await outbox.dequeueBatch()).valueOrNull!.single;
        expect(entry.entityId, customer.id);
        expect(entry.attemptCount, greaterThanOrEqualTo(1));

        // The server recovers; the retry uploads it and clears the queue.
        cloud.mode = FakeCloudMode.online;
        final Result<void> retried = await coordinator.syncNow();
        expect(retried.isOk, isTrue);
        expect((await outbox.pendingCount()).valueOrNull, 0);
        expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
      },
    );

    test('a soft delete is uploaded as a deleted row', () async {
      final Customer customer = Fixtures.customer(phone: '9100000003');
      await customers.save(customer);
      await coordinator.syncNow();

      await customers.softDelete(customer.id);
      final Result<void> result = await coordinator.syncNow();

      expect(result.isOk, isTrue);
      final Map<String, dynamic>? cloudRow = cloud.row(
        SqliteTables.customers,
        customer.id,
      );
      expect(cloudRow, isNotNull);
      expect(cloudRow!['isDeleted'], 1);
    });

    test('connectivity returning triggers a sync', () async {
      connectivity = FakeConnectivityMonitor(online: false);
      final DefaultSyncCoordinator started = DefaultSyncCoordinator(
        endpoints: buildSyncEndpoints(database, FakeRemoteStoreFactory(cloud), outbox),
        outbox: outbox,
        metadata: metadata,
        connectivity: connectivity,
      );
      addTearDown(started.dispose);

      final Customer customer = Fixtures.customer(phone: '9100000004');
      await customers.save(customer);
      started.start();

      connectivity.setOnline(true);
      // Let the connectivity-triggered cycle run.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(cloud.row(SqliteTables.customers, customer.id), isNotNull);
    });
  });

  group('download', () {
    test('a cloud record missing locally is created', () async {
      final Customer remote = Fixtures.customer(
        id: 'cus-remote-1',
        phone: '9200000001',
        name: 'From Cloud',
      );
      cloud.seed(SqliteTables.customers, remote.toMap());

      await coordinator.syncNow();

      final Customer? local = (await customers.findById('cus-remote-1'))
          .valueOrNull;
      expect(local, isNotNull);
      expect(local!.name, 'From Cloud');
      expect(
        await storedState(SqliteTables.customers, 'cus-remote-1'),
        SyncState.synced,
      );
    });

    test('a newer cloud record updates the local copy', () async {
      final DateTime t1 = DateTime.utc(2026, 1, 1, 10);
      final DateTime t2 = DateTime.utc(2026, 1, 1, 11);
      final Customer local = Customer(
        id: 'cus-shared',
        phone: '9200000002',
        name: 'Old Name',
        createdAt: t1,
        updatedAt: t1,
        syncState: SyncState.synced,
      );
      await customers.save(local);

      cloud.seed(
        SqliteTables.customers,
        local.copyWith(name: 'New Name', updatedAt: t2).toMap(),
      );

      await coordinator.syncNow();

      expect(
        (await customers.findById('cus-shared')).valueOrNull!.name,
        'New Name',
      );
    });

    test('the same id round-trips without creating a duplicate', () async {
      final Customer customer = Fixtures.customer(
        id: 'cus-stable',
        phone: '9200000003',
      );
      await customers.save(customer);
      await coordinator.syncNow(); // upload

      // Force a pull of the very record we just pushed by clearing the cursor.
      await coordinator.syncNow();

      final List<Customer> all = (await customers.findAll()).valueOrNull!;
      expect(all.where((Customer c) => c.id == 'cus-stable'), hasLength(1));
    });
  });

  group('conflict resolution', () {
    test('an older cloud record never overwrites a newer local bill', () async {
      final DateTime older = DateTime.utc(2026, 2, 1, 9);
      final DateTime newer = DateTime.utc(2026, 2, 1, 12);

      // The newer local bill: this terminal's settled total.
      final Order localBill = Fixtures.order(
        id: 'ord-conflict',
        orderNumber: 'B-1',
        total: '500.00',
        createdAt: newer,
      ).copyWith(status: OrderStatus.completed, syncState: SyncState.synced);
      await orders.save(localBill);

      // An older cloud copy with a different total.
      final Order olderCloud = Fixtures.order(
        id: 'ord-conflict',
        orderNumber: 'B-1',
        total: '100.00',
        createdAt: older,
      );
      cloud.seed(SqliteTables.orders, olderCloud.toMap());

      await coordinator.syncNow();

      // The newer local financial record wins, deterministically.
      final Order kept = (await orders.findById('ord-conflict')).valueOrNull!;
      expect(kept.totalAmount, Money.parse('500.00'));
    });

    test('a soft delete is not resurrected by an older cloud copy', () async {
      final DateTime t1 = DateTime.utc(2026, 3, 1, 9);
      final DateTime t2 = DateTime.utc(2026, 3, 1, 12);

      final Customer original = Customer(
        id: 'cus-del',
        phone: '9300000001',
        createdAt: t1,
        updatedAt: t1,
        syncState: SyncState.synced,
      );
      // Cloud still has the older, live copy.
      cloud.seed(SqliteTables.customers, original.toMap());

      // Locally deleted later.
      await customers.save(original);
      await database.database.update(
        SqliteTables.customers,
        <String, Object?>{
          SyncColumns.isDeleted: 1,
          SyncColumns.updatedAt: t2.millisecondsSinceEpoch,
          SyncColumns.syncState: SyncState.synced.name,
        },
        where: 'id = ?',
        whereArgs: <Object?>['cus-del'],
      );

      await coordinator.syncNow();

      // The older live cloud copy must not bring it back.
      expect((await customers.findById('cus-del')).valueOrNull, isNull);
    });
  });

  group('manual sync', () {
    test('reports offline as a network failure', () async {
      cloud.mode = FakeCloudMode.offline;
      await customers.save(Fixtures.customer(phone: '9400000009'));

      final Result<void> result = await coordinator.syncNow();

      // Offline is reported honestly as a network failure, and the work stays
      // queued rather than being dropped.
      expect(result.failureOrNull, isA<NetworkFailure>());
      expect((await outbox.pendingCount()).valueOrNull, greaterThan(0));
    });

    test('an unavailable cloud is a remote failure, still retryable', () async {
      cloud.mode = FakeCloudMode.unavailable;
      await customers.save(Fixtures.customer(phone: '9400000001'));

      final Result<void> result = await coordinator.syncNow();
      expect(result.failureOrNull, isA<RemoteFailure>());
      expect((await outbox.pendingCount()).valueOrNull, 1);
    });

    test('a clean run records the last successful sync time', () async {
      await customers.save(Fixtures.customer(phone: '9400000002'));
      expect((await metadata.lastSyncedAt()).valueOrNull, isNull);

      await coordinator.syncNow();

      expect((await metadata.lastSyncedAt()).valueOrNull, isNotNull);
      expect(coordinator.currentStatus.pendingCount, 0);
    });
  });
}
