import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m005_kot_order_snapshots.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m006_recipes_and_stock_deduction.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m007_held_bills.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m008_refunds.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_summary.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_record.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal already trading on v7 upgrades to v8 without losing anything, and
/// that a bill it settled before refunds existed can be refunded afterwards.
///
/// This is the case no other test can reach: every other database opens straight at the
/// latest version, so the `refunds` table is created empty against a database that has never
/// held a bill without it. Here a genuine v7 database is built with a settled bill, its
/// payment, its kitchen slip and a customer, and then opened by the current build.
void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v7-legacy-1';
  const String paymentId = 'pay-v7-legacy-1';
  const String kotId = 'kot-v7-legacy-1';
  const String customerId = 'cus-v7-legacy-1';
  const String heldBillId = 'hld-v7-legacy-1';

  /// The instant the legacy bill was settled at, as stored epoch milliseconds.
  final DateTime legacyBilledAt = DateTime.utc(2026, 1, 5, 8, 30);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v8_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion7Database(
      path,
      orderId: orderId,
      paymentId: paymentId,
      kotId: kotId,
      customerId: customerId,
      heldBillId: heldBillId,
      billedAt: legacyBilledAt,
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a v7 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    // Refunds are v8, and the migration states its own version rather than having it typed
    // in twice, which is what pins this upgrade path to the migration it is about. The
    // schema has since moved on — v9 added the GST rate and discount rule — so the current
    // version is checked as "at least v8" and the exact figure is asserted where it belongs,
    // in `migration_v9_upgrade_test.dart`.
    expect(const M008Refunds().version, 8);
    expect(SqliteDatabase.schemaVersion, greaterThanOrEqualTo(8));
  });

  test(
    'the refunds table is added with the columns a reversal needs',
    () async {
      final SqliteDatabase database = await TestDatabase.openOnDisk(path);
      addTearDown(database.close);

      final Set<String> columns = await _columnsOf(
        database,
        SqliteTables.refunds,
      );

      expect(
        columns,
        containsAll(<String>[
          'id',
          'createdAt',
          'updatedAt',
          'isDeleted',
          'syncState',
          'orderId',
          'paymentId',
          'orderNumberSnapshot',
          'paymentMethod',
          'amountPaise',
          'reason',
          'status',
        ]),
      );
      // Money is integer paise in a column named for it, like every other amount here.
      expect(columns, contains('amountPaise'));
      // And there is no decimal or floating point column pretending to hold an amount.
      expect(
        columns.any((String name) => name.toLowerCase().contains('amountreal')),
        isFalse,
      );
    },
  );

  test('the one-refund-per-bill index is created', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> indexes = await database.database.rawQuery(
      'PRAGMA index_list(${SqliteTables.refunds})',
    );
    final Set<String> names = indexes
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();

    expect(names, contains('idx_refunds_order'));
    expect(names, contains('idx_refunds_payment'));
    expect(names, contains('idx_refunds_status'));
    expect(names, contains('idx_refunds_method'));

    // Unique, and partial on isDeleted, which is what makes it an idempotency key that
    // survives soft deletion.
    final Map<String, Object?> orderIndex = indexes.firstWhere(
      (Map<String, Object?> row) => row['name'] == 'idx_refunds_order',
    );
    expect(orderIndex['unique'], 1);
    expect(orderIndex['partial'], 1);
  });

  test('no column was added to the payments table', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Set<String> columns = await _columnsOf(
      database,
      SqliteTables.payments,
    );

    // The tender's shape is untouched. A `refundedPaise` column on the payment would be a
    // second place the same fact lived, and the first thing to disagree with the refunds
    // table.
    expect(columns, <String>{
      'id',
      'createdAt',
      'updatedAt',
      'isDeleted',
      'syncState',
      'orderId',
      'paymentMethod',
      'amountPaise',
      'reference',
      'status',
    });
  });

  test('no column was added to the orders table', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Set<String> columns = await _columnsOf(database, SqliteTables.orders);

    expect(columns, isNot(contains('refundedAmountPaise')));
    expect(columns, isNot(contains('refundedPaise')));
    // And still no table management, which the schema has never had.
    expect(columns, isNot(contains('tableId')));
  });

  test('the existing bill, payment, slip and customer all survive', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Order? order = (await SqliteOrderRepository(
      database: database,
    ).findOrder(orderId)).valueOrNull;
    expect(order, isNotNull);
    expect(order!.orderNumber, '20260105-0003');
    expect(order.status, OrderStatus.completed);
    expect(order.totalAmount.paise, 32000);

    final List<Payment> tendered = (await SqlitePaymentRepository(
      database: database,
    ).loadForOrder(orderId)).valueOrNull!;
    expect(tendered, hasLength(1));
    expect(tendered.single.amount.paise, 32000);
    expect(tendered.single.status, PaymentStatus.completed);

    final KotRecord? slip = (await SqliteKotRepository(
      database: database,
    ).findKot(kotId)).valueOrNull;
    expect(slip, isNotNull);
    expect(slip!.kotNumber, 'K20260105-0002');

    expect(
      (await SqliteCustomerRepository(database: database)
              .findByPhone('9000000055'))
          .valueOrNull!
          .id,
      customerId,
    );
  });

  test('the held bill from v7 survives', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> held = await database.database.query(
      SqliteTables.heldBills,
    );
    expect(held, hasLength(1));
    expect(held.single['id'], heldBillId);
  });

  test('the seeded menu survives', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<MenuItem> items = (await SqliteMenuRepository(
      database: database,
    ).loadItems()).valueOrNull!;

    expect(items, isNotEmpty);
    expect(
      items.map((MenuItem item) => item.name),
      contains('Cheese Pizza'),
      reason: 'the seeded menu must not be re-seeded or dropped',
    );
  });

  test(
    'a bill settled before refunds existed reads as fully refundable',
    () async {
      final SqliteDatabase database = await TestDatabase.openOnDisk(path);
      addTearDown(database.close);

      final RefundableBill bill = (await SqliteRefundRepository(
        database: database,
      ).loadRefundable(orderId)).valueOrNull!;

      expect(bill.orderNumber, '20260105-0003');
      expect(bill.paidAmount.paise, 32000);
      // No refunds table existed when this bill was taken, so nothing can have been refunded.
      expect(bill.refundedAmount.paise, 0);
      expect(bill.refundableAmount.paise, 32000);
      expect(bill.canRefund, isTrue);
    },
  );

  test('a bill settled before refunds existed can be refunded', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteRefundRepository refunds = SqliteRefundRepository(
      database: database,
    );
    final RefundableBill bill = (await refunds.loadRefundable(orderId))
        .valueOrNull!;

    final Refund written = (await refunds.refund(
      RefundRequest.forBill(bill, at: DateTime.utc(2026, 1, 6, 10)),
    )).valueOrNull!;

    expect(written.amount.paise, 32000);
    expect(written.paymentId, paymentId);
    expect(written.paymentMethod, PaymentMethod.cash);
    expect(written.orderNumberSnapshot, '20260105-0003');

    // And the legacy tender is still exactly as it was written under v7.
    final Payment tender = (await SqlitePaymentRepository(
      database: database,
    ).loadForOrder(orderId)).valueOrNull!.single;
    expect(tender.status, PaymentStatus.completed);
    expect(tender.amount.paise, 32000);
  });

  test('the upgraded reports net a legacy bill correctly', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteRefundRepository refunds = SqliteRefundRepository(
      database: database,
    );
    final SqliteSalesReportRepository reports = SqliteSalesReportRepository(
      database: database,
    );
    final DateRange thatDay = DateRange.day(legacyBilledAt.toLocal());

    final SalesSummary before = (await reports.loadSummary(thatDay))
        .valueOrNull!;
    expect(before.grossSales.paise, 32000);
    expect(before.refundTotal.paise, 0);

    await refunds.refund(
      RefundRequest.forBill(
        (await refunds.loadRefundable(orderId)).valueOrNull!,
        at: DateTime.utc(2026, 1, 6, 10),
      ),
    );

    final SalesSummary after = (await reports.loadSummary(thatDay))
        .valueOrNull!;
    expect(after.billCount, 1);
    expect(after.grossSales.paise, 32000);
    expect(after.refundTotal.paise, 32000);
    expect(after.netSales.paise, 0);
  });

  test('the upgraded customer summary nets a legacy refund', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteCustomerRepository customers = SqliteCustomerRepository(
      database: database,
    );
    final SqliteRefundRepository refunds = SqliteRefundRepository(
      database: database,
    );

    final CustomerSummary before = (await customers.loadSummary(customerId))
        .valueOrNull!;
    expect(before.completedOrderCount, 1);
    expect(before.totalSpent.paise, 32000);
    expect(before.refundedTotal.paise, 0);
    expect(before.netSpent.paise, 32000);

    await refunds.refund(
      RefundRequest.forBill(
        (await refunds.loadRefundable(orderId)).valueOrNull!,
        at: DateTime.utc(2026, 1, 6, 10),
      ),
    );

    final CustomerSummary after = (await customers.loadSummary(customerId))
        .valueOrNull!;
    expect(after.completedOrderCount, 1);
    expect(after.totalSpent.paise, 32000);
    expect(after.refundedTotal.paise, 32000);
    expect(after.netSpent.paise, 0);
  });

  test('foreign keys hold across the whole upgraded database', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteRefundRepository refunds = SqliteRefundRepository(
      database: database,
    );
    await refunds.refund(
      RefundRequest.forBill(
        (await refunds.loadRefundable(orderId)).valueOrNull!,
        at: DateTime.utc(2026, 1, 6, 10),
      ),
    );

    final List<Map<String, Object?>> violations = await database.database
        .rawQuery('PRAGMA foreign_key_check');

    expect(violations, isEmpty);
  });

  test('a refund cannot point at a bill that is not there', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    // The constraints are live rather than decorative on the new table too.
    await expectLater(
      database.database.insert(SqliteTables.refunds, <String, Object?>{
        'id': 'ref-orphan',
        'createdAt': 0,
        'updatedAt': 0,
        'isDeleted': 0,
        'syncState': 'pending',
        'orderId': 'ord-does-not-exist',
        'paymentId': paymentId,
        'orderNumberSnapshot': 'nowhere',
        'paymentMethod': 'cash',
        'amountPaise': 100,
        'status': 'completed',
      }),
      throwsA(isA<Object>()),
    );
  });

  test('a refund cannot point at a tender that is not there', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    await expectLater(
      database.database.insert(SqliteTables.refunds, <String, Object?>{
        'id': 'ref-orphan-tender',
        'createdAt': 0,
        'updatedAt': 0,
        'isDeleted': 0,
        'syncState': 'pending',
        'orderId': orderId,
        'paymentId': 'pay-does-not-exist',
        'orderNumberSnapshot': '20260105-0003',
        'paymentMethod': 'cash',
        'amountPaise': 100,
        'status': 'completed',
      }),
      throwsA(isA<Object>()),
    );
  });

  test('a fresh database and an upgraded one agree on the schema', () async {
    // The guarantee the migration runner exists for: a new terminal and an upgraded one end
    // up with the same tables and the same columns.
    final SqliteDatabase upgraded = await TestDatabase.openOnDisk(path);
    addTearDown(upgraded.close);
    final SqliteDatabase fresh = await TestDatabase.openInMemory();
    addTearDown(fresh.close);

    expect(await _tablesOf(upgraded), await _tablesOf(fresh));
    expect(
      await _columnsOf(upgraded, SqliteTables.refunds),
      await _columnsOf(fresh, SqliteTables.refunds),
    );
    expect(
      await _indexesOf(upgraded, SqliteTables.refunds),
      await _indexesOf(fresh, SqliteTables.refunds),
    );
    expect(
      await _columnsOf(upgraded, SqliteTables.payments),
      await _columnsOf(fresh, SqliteTables.payments),
    );
  });
}

Future<Set<String>> _columnsOf(SqliteDatabase database, String table) async {
  final List<Map<String, Object?>> rows = await database.database.rawQuery(
    'PRAGMA table_info($table)',
  );
  return rows.map((Map<String, Object?> row) => row['name']! as String).toSet();
}

Future<Set<String>> _indexesOf(SqliteDatabase database, String table) async {
  final List<Map<String, Object?>> rows = await database.database.rawQuery(
    'PRAGMA index_list($table)',
  );
  return rows.map((Map<String, Object?> row) => row['name']! as String).toSet();
}

Future<Set<String>> _tablesOf(SqliteDatabase database) async {
  final List<Map<String, Object?>> rows = await database.database.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((Map<String, Object?> row) => row['name']! as String).toSet();
}

/// Builds a database in exactly the state migration v7 left it in.
///
/// The seven shipped migrations are replayed, then a settled bill with its customer, its
/// tender and its kitchen slip is inserted, plus a held bill. The rows are written by hand
/// rather than through the repositories on purpose: a repository compiled against the current
/// build could only ever produce current rows, and the point is to open rows written before
/// the refunds table existed.
Future<void> _createVersion7Database(
  String path, {
  required String orderId,
  required String paymentId,
  required String kotId,
  required String customerId,
  required String heldBillId,
  required DateTime billedAt,
}) async {
  final int at = billedAt.millisecondsSinceEpoch;

  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 7,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await const M004ScopedMenuOptions().migrate(db);
        await const M005KotOrderSnapshots().migrate(db);
        await const M006RecipesAndStockDeduction().migrate(db);
        await const M007HeldBills().migrate(db);

        await db.insert(SqliteTables.customers, <String, Object?>{
          'id': customerId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'name': 'Legacy Customer',
          'phone': '9000000055',
        });

        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260105-0003',
          'orderType': 'takeaway',
          'status': 'completed',
          'customerId': customerId,
          'subtotalPaise': 30000,
          'discountAmountPaise': 0,
          'taxAmountPaise': 2000,
          'totalAmountPaise': 32000,
        });

        await db.insert(SqliteTables.orderItems, <String, Object?>{
          'id': 'oit-v7-legacy-1',
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'itemNameSnapshot': 'Legacy Pizza',
          'variantNameSnapshot': 'Large',
          'quantity': 2,
          'unitPricePaise': 15000,
          'totalAmountPaise': 30000,
        });

        await db.insert(SqliteTables.payments, <String, Object?>{
          'id': paymentId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'paymentMethod': 'cash',
          'amountPaise': 32000,
          'status': 'completed',
        });

        await db.insert(SqliteTables.kotRecords, <String, Object?>{
          'id': kotId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'kotNumber': 'K20260105-0002',
          'status': 'completed',
          'orderNumber': '20260105-0003',
          'orderType': 'takeaway',
        });

        await db.insert(SqliteTables.heldBills, <String, Object?>{
          'id': heldBillId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderType': 'takeaway',
          'status': 'held',
          'subtotalPaise': 25000,
          'lineCount': 1,
          'itemCount': 1,
        });
      },
    ),
  );
  await database.close();
}
