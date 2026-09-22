import 'package:brisko_billing/app/sync/sync_endpoints.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_local_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/initial_sync_service.dart';
import 'package:brisko_billing/core/data/sync/sync_endpoint.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_cloud.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late FakeCloud cloud;
  late SqliteSyncMetadataStore metadata;
  late List<SyncEndpointBase> endpoints;
  late SqliteLocalStore<Customer> customers;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    cloud = FakeCloud();
    metadata = SqliteSyncMetadataStore(database: database);
    final SqliteOutboxStore outbox = SqliteOutboxStore(database: database);
    endpoints = buildSyncEndpoints(database, FakeRemoteStoreFactory(cloud), outbox);
    customers = SqliteLocalStore<Customer>(
      database: database,
      table: SqliteTables.customers,
      fromRow: Customer.fromRow,
      outbox: outbox,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<bool> hasOperationalData() async {
    for (final String table in operationalTables) {
      final List<Map<String, Object?>> rows = await database.database.rawQuery(
        'SELECT 1 FROM $table LIMIT 1',
      );
      if (rows.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  InitialSyncService service() => InitialSyncService(
    endpoints: endpoints,
    metadata: metadata,
    hasOperationalData: hasOperationalData,
  );

  test('an empty terminal restores from the cloud', () async {
    cloud.seed(
      SqliteTables.customers,
      Fixtures.customer(id: 'cus-cloud', phone: '9000000009').toMap(),
    );

    final Result<InitialSyncOutcome> result = await service().run();

    expect(result.valueOrNull, InitialSyncOutcome.restoredFromCloud);
    expect((await customers.findById('cus-cloud')).valueOrNull, isNotNull);
    expect((await metadata.isBootstrapped()).valueOrNull, isTrue);
  });

  test('an empty terminal against an empty cloud is a fresh start', () async {
    final Result<InitialSyncOutcome> result = await service().run();

    expect(result.valueOrNull, InitialSyncOutcome.cloudEmpty);
    expect((await metadata.isBootstrapped()).valueOrNull, isTrue);
  });

  test('a terminal already in use is never overwritten by the cloud', () async {
    // This terminal has taken a real bill.
    final SqliteLocalStore<Customer> local = customers;
    await database.database.insert(SqliteTables.orders, <String, Object?>{
      'id': 'ord-local',
      'createdAt': 0,
      'updatedAt': 0,
      'isDeleted': 0,
      'syncState': 'pending',
      'orderNumber': 'L-1',
      'orderType': 'takeaway',
      'status': 'completed',
      'subtotalPaise': 100,
      'discountAmountPaise': 0,
      'taxAmountPaise': 0,
      'totalAmountPaise': 100,
    });

    // The cloud holds a customer this terminal has never seen.
    cloud.seed(
      SqliteTables.customers,
      Fixtures.customer(id: 'cus-cloud-2', phone: '9000000010').toMap(),
    );

    final Result<InitialSyncOutcome> result = await service().run();

    expect(result.valueOrNull, InitialSyncOutcome.keptExistingLocal);
    // The restore did not run, so the cloud customer was not pulled over the
    // in-use terminal here; ordinary sync will merge it later.
    expect((await local.findById('cus-cloud-2')).valueOrNull, isNull);
    expect((await metadata.isBootstrapped()).valueOrNull, isTrue);
  });

  test('a second run is a no-op once bootstrapped', () async {
    await service().run();
    final Result<InitialSyncOutcome> second = await service().run();
    expect(second.valueOrNull, InitialSyncOutcome.alreadyBootstrapped);
  });

  test(
    'an offline cloud defers the restore without marking bootstrapped',
    () async {
      cloud.mode = FakeCloudMode.offline;

      final Result<InitialSyncOutcome> result = await service().run();

      expect(result.failureOrNull, isA<NetworkFailure>());
      // Not bootstrapped: a later online run can still restore.
      expect((await metadata.isBootstrapped()).valueOrNull, isFalse);
    },
  );

  test('restoring twice does not duplicate records', () async {
    cloud.seed(
      SqliteTables.customers,
      Fixtures.customer(id: 'cus-once', phone: '9000000011').toMap(),
    );

    await service().run();
    // Re-apply the same cloud data through the endpoint pull path.
    for (final SyncEndpointBase endpoint in endpoints) {
      await endpoint.pull(null);
    }

    final List<Customer> all = (await customers.findAll()).valueOrNull!;
    expect(all.where((Customer c) => c.id == 'cus-once'), hasLength(1));
  });
}
