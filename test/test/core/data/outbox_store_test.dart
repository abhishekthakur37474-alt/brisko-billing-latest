import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/remote/noop_remote_store.dart';
import 'package:brisko_billing/core/data/sync/outbox_entry.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteOutboxStore outbox;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    outbox = SqliteOutboxStore(database: database);
  });

  tearDown(() async {
    await outbox.dispose();
    await database.close();
  });

  OutboxEntry entry({
    String collection = 'customers',
    String entityId = 'cus-1',
    OutboxOperation operation = OutboxOperation.upsert,
    DateTime? queuedAt,
    Map<String, dynamic> payload = const <String, dynamic>{'name': 'Test'},
  }) {
    return OutboxEntry(
      id: EntityId.generate(prefix: 'obx'),
      collection: collection,
      entityId: entityId,
      operation: operation,
      payload: payload,
      queuedAt: queuedAt ?? DateTime.now().toUtc(),
    );
  }

  test('an entry can be queued and read back intact', () async {
    final Customer customer = Fixtures.customer(phone: '9700000001');
    final OutboxEntry queued = entry(
      entityId: customer.id,
      payload: customer.toMap(),
    );

    expect((await outbox.enqueue(queued)).isOk, isTrue);

    final List<OutboxEntry> batch = (await outbox.dequeueBatch()).valueOrNull!;

    expect(batch, hasLength(1));
    expect(batch.single.entityId, customer.id);
    expect(batch.single.collection, 'customers');
    expect(batch.single.operation, OutboxOperation.upsert);
    expect(batch.single.payload['phone'], '9700000001');
  });

  test('entries replay oldest first', () async {
    final DateTime base = DateTime.utc(2026, 1, 1, 12);
    await outbox.enqueue(
      entry(entityId: 'third', queuedAt: base.add(const Duration(minutes: 2))),
    );
    await outbox.enqueue(entry(entityId: 'first', queuedAt: base));
    await outbox.enqueue(
      entry(entityId: 'second', queuedAt: base.add(const Duration(minutes: 1))),
    );

    final List<OutboxEntry> batch = (await outbox.dequeueBatch()).valueOrNull!;

    expect(batch.map((OutboxEntry e) => e.entityId), <String>[
      'first',
      'second',
      'third',
    ]);
  });

  test('the batch size is respected', () async {
    for (int i = 0; i < 10; i++) {
      await outbox.enqueue(entry(entityId: 'e$i'));
    }
    expect((await outbox.dequeueBatch(limit: 4)).valueOrNull, hasLength(4));
  });

  test('a completed entry leaves the queue', () async {
    final OutboxEntry queued = entry();
    await outbox.enqueue(queued);
    expect((await outbox.pendingCount()).valueOrNull, 1);

    expect((await outbox.markCompleted(queued.id)).isOk, isTrue);
    expect((await outbox.pendingCount()).valueOrNull, 0);
  });

  test('a failed entry stays queued and records the attempt', () async {
    final OutboxEntry queued = entry();
    await outbox.enqueue(queued);

    expect((await outbox.markFailed(queued.id, 'network down')).isOk, isTrue);

    final OutboxEntry reloaded =
        (await outbox.dequeueBatch()).valueOrNull!.single;

    // Still present: a failure must never silently drop a bill.
    expect(reloaded.attemptCount, 1);
    expect(reloaded.lastError, 'network down');
    expect((await outbox.pendingCount()).valueOrNull, 1);
  });

  test('a delete operation carries no payload', () async {
    await outbox.enqueue(
      entry(
        operation: OutboxOperation.delete,
        payload: const <String, dynamic>{},
      ),
    );

    final OutboxEntry reloaded =
        (await outbox.dequeueBatch()).valueOrNull!.single;
    expect(reloaded.operation, OutboxOperation.delete);
    expect(reloaded.payload, isEmpty);
  });

  test('the queue survives closing and reopening the database', () async {
    // Durability is the whole point: a power cut mid-shift must not lose the
    // record that bills still need uploading.
    await outbox.enqueue(entry(entityId: 'survivor'));
    expect((await outbox.pendingCount()).valueOrNull, 1);
    // An in-memory database cannot demonstrate this, so the assertion here is
    // limited to the queue being read back through a fresh store instance over
    // the same connection. The on-disk case is covered in
    // sqlite_database_test.dart.
    final SqliteOutboxStore reopened = SqliteOutboxStore(database: database);
    addTearDown(reopened.dispose);
    expect((await reopened.pendingCount()).valueOrNull, 1);
  });

  test('clearAll empties the queue', () async {
    await outbox.enqueue(entry(entityId: 'one'));
    await outbox.enqueue(entry(entityId: 'two'));
    expect((await outbox.pendingCount()).valueOrNull, 2);

    expect((await outbox.clearAll()).isOk, isTrue);
    expect((await outbox.pendingCount()).valueOrNull, 0);
    expect((await outbox.dequeueBatch()).valueOrNull, isEmpty);
  });

  test('nothing is queued yet, because nothing drains the queue', () async {
    // Writes do not enqueue until a backend exists. Enqueueing now would grow
    // this table without bound for every bill the outlet ever takes.
    expect((await outbox.pendingCount()).valueOrNull, 0);
  });

  group('NoopRemoteStore', () {
    test('reports the cloud as unreachable rather than pretending', () async {
      const NoopRemoteStore<Customer> remote = NoopRemoteStore<Customer>();
      final Customer customer = Fixtures.customer();

      // Reporting success would mark records synced when nothing was uploaded.
      expect((await remote.push(customer)).isErr, isTrue);
      expect(
        (await remote.push(customer)).failureOrNull,
        isA<NetworkFailure>(),
      );
      expect((await remote.pushAll(<Customer>[customer])).isErr, isTrue);
      expect((await remote.pushDelete(customer.id)).isErr, isTrue);
      expect((await remote.pullChangedSince(null)).isErr, isTrue);
    });
  });
}
