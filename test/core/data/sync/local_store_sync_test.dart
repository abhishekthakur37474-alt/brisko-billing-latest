import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_local_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/remote_merge_report.dart';
import 'package:brisko_billing/core/data/sync/sync_state.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteLocalStore<Customer> customers;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    customers = SqliteLocalStore<Customer>(
      database: database,
      table: SqliteTables.customers,
      fromRow: Customer.fromRow,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<String?> storedState(String id) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      SqliteTables.customers,
      columns: <String>[SyncColumns.syncState],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first[SyncColumns.syncState] as String?;
  }

  Customer customerAt(String id, DateTime at, {String name = 'A'}) => Customer(
    id: id,
    phone: '900',
    name: name,
    createdAt: at,
    updatedAt: at,
    syncState: SyncState.pending,
  );

  group('markSynced', () {
    test('marks a record synced when the version matches', () async {
      final DateTime at = DateTime.utc(2026, 1, 1);
      await customers.save(customerAt('c1', at));

      final Result<void> result = await customers.markSynced('c1', at);

      expect(result.isOk, isTrue);
      expect(await storedState('c1'), SyncState.synced.name);
    });

    test(
      'leaves a record pending when it changed after being pushed',
      () async {
        final DateTime pushed = DateTime.utc(2026, 1, 1, 10);
        final DateTime edited = DateTime.utc(2026, 1, 1, 11);
        await customers.save(customerAt('c2', edited));

        // The push carried the earlier version; the record has moved on since.
        await customers.markSynced('c2', pushed);

        expect(await storedState('c2'), SyncState.pending.name);
      },
    );
  });

  group('applyRemoteChanges', () {
    test('an empty batch is a no-op', () async {
      final RemoteMergeReport report = (await customers.applyRemoteChanges(
        <Customer>[],
      )).valueOrNull!;
      expect(report.total, 0);
    });

    test('writes a record that is absent locally, marked synced', () async {
      final RemoteMergeReport report = (await customers.applyRemoteChanges(
        <Customer>[customerAt('c3', DateTime.utc(2026, 1, 1))],
      )).valueOrNull!;

      expect(report.applied, 1);
      expect(report.keptLocal, 0);
      expect(await storedState('c3'), SyncState.synced.name);
    });

    test('a strictly newer remote record overwrites the local one', () async {
      await customers.save(
        customerAt('c4', DateTime.utc(2026, 1, 1), name: 'Old'),
      );

      final RemoteMergeReport report = (await customers.applyRemoteChanges(
        <Customer>[customerAt('c4', DateTime.utc(2026, 1, 2), name: 'New')],
      )).valueOrNull!;

      expect(report.applied, 1);
      expect((await customers.findById('c4')).valueOrNull!.name, 'New');
    });

    test(
      'an older remote record is held back to protect the local copy',
      () async {
        await customers.save(
          customerAt('c5', DateTime.utc(2026, 1, 2), name: 'Local newer'),
        );

        final RemoteMergeReport report = (await customers.applyRemoteChanges(
          <Customer>[
            customerAt('c5', DateTime.utc(2026, 1, 1), name: 'Remote older'),
          ],
        )).valueOrNull!;

        expect(report.applied, 0);
        expect(report.keptLocal, 1);
        expect(
          (await customers.findById('c5')).valueOrNull!.name,
          'Local newer',
        );
      },
    );

    test('re-applying the same record does not duplicate it', () async {
      final Customer c = customerAt('c6', DateTime.utc(2026, 1, 1));
      await customers.applyRemoteChanges(<Customer>[c]);
      await customers.applyRemoteChanges(<Customer>[c]);

      final List<Customer> all = (await customers.findAll()).valueOrNull!;
      expect(all.where((Customer x) => x.id == 'c6'), hasLength(1));
    });
  });

  group('a local save re-queues an already-synced record', () {
    test('an edit of a synced row is pending again and found unsynced', () async {
      final DateTime created = DateTime.utc(2026, 1, 1, 9);
      await customers.save(customerAt('c7', created));
      await customers.markSynced('c7', created);
      expect(await storedState('c7'), SyncState.synced.name);

      // What an editor does: read the stored row back, then save it with a new
      // timestamp. `copyWith` preserves the stored syncState, which is `synced`.
      final Customer stored = (await customers.findById('c7')).valueOrNull!;
      final Customer edited = stored.copyWith(
        name: 'Renamed',
        updatedAt: DateTime.utc(2026, 1, 1, 10),
      );
      expect(edited.syncState, SyncState.synced);

      final Result<void> result = await customers.save(edited);
      expect(result.isOk, isTrue);

      expect(await storedState('c7'), SyncState.pending.name);
      final List<Customer> unsynced =
          (await customers.findUnsynced()).valueOrNull!;
      expect(unsynced.map((Customer c) => c.id), contains('c7'));
    });
  });
}
