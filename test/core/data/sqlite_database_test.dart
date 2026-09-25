import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  group('database initialisation', () {
    late SqliteDatabase database;

    setUp(() async {
      database = await TestDatabase.openInMemory();
    });

    tearDown(() async {
      await database.close();
    });

    test('opens successfully', () {
      expect(database.isOpen, isTrue);
    });

    test('reports the schema version the migrations define', () async {
      final int version = await database.database.getVersion();
      expect(version, SqliteDatabase.schemaVersion);
      // Sixteen migrations: schema through expenses, the RTDB resync, then
      // the customer-name snapshot on a settled bill, the supplied menu
      // specification, and the delivery-address snapshot.
      expect(SqliteDatabase.schemaVersion, 16);
    });

    test('creates every table the POS needs', () async {
      final List<Map<String, Object?>> rows = await database.database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final Set<String> tables = rows
          .map((Map<String, Object?> row) => row['name']! as String)
          .toSet();

      expect(
        tables,
        containsAll(<String>[
          SqliteTables.categories,
          SqliteTables.menuItems,
          SqliteTables.menuItemVariants,
          SqliteTables.menuItemOptions,
          SqliteTables.orders,
          SqliteTables.orderItems,
          SqliteTables.orderItemOptions,
          SqliteTables.payments,
          SqliteTables.customers,
          SqliteTables.inventoryItems,
          SqliteTables.stockMovements,
          SqliteTables.kotRecords,
          SqliteTables.kotItems,
          SqliteTables.kotItemOptions,
          SqliteTables.recipeIngredients,
          SqliteTables.orderInventoryDeductions,
          SqliteTables.settings,
          SqliteTables.outbox,
        ]),
      );
    });

    test('does not create a table reference on orders', () async {
      // Dine-in is supported but digital table management is out of scope, so the
      // schema must not carry a table or seat column.
      final List<Map<String, Object?>> columns = await database.database
          .rawQuery('PRAGMA table_info(${SqliteTables.orders})');
      final Set<String> names = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toSet();

      expect(names, isNot(contains('tableId')));
      expect(names, isNot(contains('tableNumber')));
    });

    test('enforces foreign keys', () async {
      final List<Map<String, Object?>> rows = await database.database.rawQuery(
        'PRAGMA foreign_keys',
      );
      expect(rows.first.values.first, 1);
    });

    test('rejects an order line that references a missing order', () async {
      // Proves the constraints are live, not decorative.
      await expectLater(
        database.database.insert(SqliteTables.orderItems, <String, Object?>{
          'id': 'oit-orphan',
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'pending',
          'orderId': 'ord-does-not-exist',
          'itemNameSnapshot': 'Orphan',
          'quantity': 1,
          'unitPricePaise': 100,
          'totalAmountPaise': 100,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('throws a clear error when used before open', () async {
      final SqliteDatabase unopened = SqliteDatabase();
      expect(() => unopened.database, throwsA(isA<StateError>()));
    });
  });

  group('persistence across a reopen', () {
    late Directory directory;
    late String path;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('brisko_db_test');
      path = p.join(directory.path, 'reopen.db');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'data written before closing is still present after reopening',
      () async {
        final SqliteDatabase first = await TestDatabase.openOnDisk(path);
        final Customer customer = Fixtures.customer(phone: '9111100001');

        final SqliteCustomerRepository firstRepository =
            SqliteCustomerRepository(database: first);
        expect((await firstRepository.save(customer)).isOk, isTrue);
        await first.close();

        final SqliteDatabase second = await TestDatabase.openOnDisk(path);
        addTearDown(second.close);

        final SqliteCustomerRepository secondRepository =
            SqliteCustomerRepository(database: second);
        final Customer? reloaded = (await secondRepository.findByPhone(
          '9111100001',
        )).valueOrNull;

        expect(reloaded, isNotNull);
        expect(reloaded!.id, customer.id);
        expect(reloaded.phone, '9111100001');
      },
    );

    test(
      'reopening runs no migration twice and keeps the version stable',
      () async {
        final SqliteDatabase first = await TestDatabase.openOnDisk(path);
        final int firstVersion = await first.database.getVersion();
        await first.close();

        final SqliteDatabase second = await TestDatabase.openOnDisk(path);
        addTearDown(second.close);
        final int secondVersion = await second.database.getVersion();

        expect(secondVersion, firstVersion);
        expect(secondVersion, SqliteDatabase.schemaVersion);
      },
    );
  });
}
