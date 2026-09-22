import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_record.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal already holding kitchen slips upgrades to v5 correctly.
///
/// This is the case no other test can reach: every other database opens straight at
/// the latest version, so `kot_records` is empty when v5 runs and the backfill has
/// nothing to do. Here a genuine v4 database is built with a real order and a slip in
/// the old three-column shape, and then opened by the current build.
void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-legacy-1';
  const String kotId = 'kot-legacy-1';

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v5_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion4Database(path, orderId: orderId, kotId: kotId);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v4 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    // Reaches the current version, whatever that is now: a v4 database runs v5 and
    // every migration added after it. The exact number is asserted where it belongs,
    // in the database test and in each version's own upgrade test.
    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    expect(SqliteDatabase.schemaVersion, greaterThanOrEqualTo(5));
  });

  test('an existing slip is backfilled from the order it came from', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);
    final SqliteKotRepository kots = SqliteKotRepository(database: database);

    final KotRecord? slip = (await kots.findKot(kotId)).valueOrNull;

    expect(slip, isNotNull);
    // Real values taken from the parent order, not the placeholder the ALTER
    // needed.
    expect(slip!.orderNumber, '20260101-0007');
    expect(slip.orderType, OrderType.delivery);
    expect(slip.notes, 'No onions');
    // Untouched by the upgrade.
    expect(slip.kotNumber, 'K20260101-0001');
    expect(slip.status, KotStatus.pending);
    expect(slip.orderId, orderId);
  });

  test('the backfilled slip is readable as a board ticket', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);
    final SqliteKotRepository kots = SqliteKotRepository(database: database);

    final List<KitchenTicket> board =
        (await kots.loadActiveTickets()).valueOrNull!;

    expect(board, hasLength(1));
    expect(board.single.orderNumber, '20260101-0007');
    expect(board.single.orderType, OrderType.delivery);
    // The old slip had no lines, and none were invented for it.
    expect(board.single.lines, isEmpty);
  });

  test('the slip line option table is added', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> columns = await database.database.rawQuery(
      'PRAGMA table_info(${SqliteTables.kotItemOptions})',
    );
    final Set<String> names = columns
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();

    expect(
      names,
      containsAll(<String>['kotItemId', 'optionNameSnapshot', 'quantity']),
    );
    // No price on a kitchen slip.
    expect(names, isNot(contains('pricePaise')));
  });

  test('an upgraded database accepts a new slip', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);
    final SqliteKotRepository kots = SqliteKotRepository(database: database);

    // The number follows today's date, so it does not collide with the legacy row.
    final String number = (await kots.nextKotNumber()).valueOrNull!;
    expect(number, matches(RegExp(r'^K\d{8}-0001$')));
  });
}

/// Builds a database in exactly the state migration v4 left it in.
///
/// The four shipped migrations are replayed, then an order and a slip are inserted
/// using only the columns v4 had. Writing the rows by hand rather than through the
/// models is the point: the models now carry columns that did not exist yet.
Future<void> _createVersion4Database(
  String path, {
  required String orderId,
  required String kotId,
}) async {
  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 4,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await const M004ScopedMenuOptions().migrate(db);

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260101-0007',
          'orderType': 'delivery',
          'status': 'completed',
          'subtotalPaise': 32000,
          'totalAmountPaise': 32000,
          'notes': 'No onions',
        });

        await db.insert(SqliteTables.kotRecords, <String, Object?>{
          'id': kotId,
          'createdAt': 0,
          'updatedAt': 0,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'kotNumber': 'K20260101-0001',
          'status': 'pending',
        });
      },
    ),
  );
  await database.close();
}
