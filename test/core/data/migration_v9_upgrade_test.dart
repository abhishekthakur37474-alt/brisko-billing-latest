import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/migrations/m001_initial_schema.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m002_seed_menu.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m003_seed_menu_products.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m004_scoped_menu_options.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m005_kot_order_snapshots.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m006_recipes_and_stock_deduction.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m007_held_bills.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m008_refunds.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/m009_bill_tax_and_discount.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/gst_rate.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/printing/data/repository_sale_print_document_source.dart';
import 'package:brisko_billing/features/printing/data/settings_business_identity_source.dart';
import 'package:brisko_billing/features/printing/domain/models/print_document.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_documents.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

/// Proves that a terminal already trading on v8 upgrades to v9 and that the bills it
/// settled before GST existed keep reading, printing, reporting and refunding correctly.
///
/// This is the case no other test can reach. Every other database opens straight at the
/// latest version, so `taxRateBasisPoints` is created against rows that were written with
/// it in mind. Here a genuine v8 database is built with a bill that predates the column
/// entirely, and then opened by the current build.
///
/// The claim under test is the backward-compatibility one: an existing bill charged no
/// discount and no tax, so it must read back as exactly that — not as an unknown, and not
/// as today's rate applied retrospectively.
void main() {
  setUpAll(TestDatabase.register);

  const String orderId = 'ord-v8-legacy-1';
  const String paymentId = 'pay-v8-legacy-1';
  const String kotId = 'kot-v8-legacy-1';
  const String customerId = 'cus-v8-legacy-1';

  /// The instant the legacy bill was settled at.
  final DateTime legacyBilledAt = DateTime.utc(2026, 2, 10, 9, 15);

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('brisko_v9_upgrade');
    path = p.join(directory.path, 'upgrade.db');
    await _createVersion8Database(
      path,
      orderId: orderId,
      paymentId: paymentId,
      kotId: kotId,
      customerId: customerId,
      billedAt: legacyBilledAt,
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Set<String>> columnsOf(SqliteDatabase database, String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'PRAGMA table_info($table)',
    );
    return rows
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();
  }

  test('a v8 database reaches the current schema version', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    expect(await database.database.getVersion(), SqliteDatabase.schemaVersion);
    // The migration states its own version rather than having it typed in twice, and the
    // database version is derived from the list, so these two together are what say the
    // list grew by exactly this migration.
    expect(const M009BillTaxAndDiscount().version, 9);
    expect(SqliteDatabase.schemaVersion, 15);
  });

  test('the three columns are added to the orders table', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Set<String> columns = await columnsOf(database, SqliteTables.orders);

    expect(
      columns,
      containsAll(<String>[
        'taxRateBasisPoints',
        'discountType',
        'discountValue',
      ]),
    );
    // The amount columns are reused, not duplicated. A second discount or tax amount would
    // be a second place the same figure lived.
    expect(columns, contains('discountAmountPaise'));
    expect(columns, contains('taxAmountPaise'));
    expect(columns.where((String name) => name.contains('Paise')), <String>{
      'subtotalPaise',
      'discountAmountPaise',
      'taxAmountPaise',
      'totalAmountPaise',
    });
    // And the rule's magnitude is deliberately not named as an amount: for a percentage it
    // is not money.
    expect(columns, isNot(contains('discountValuePaise')));
    // No table management, which the schema has never had.
    expect(columns, isNot(contains('tableId')));
  });

  test('no other table was touched', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    // The rate belongs to the bill as a whole. A per-line rate would be a second tax model
    // and the first thing to disagree with the header.
    expect(await columnsOf(database, SqliteTables.orderItems), <String>{
      'id',
      'createdAt',
      'updatedAt',
      'isDeleted',
      'syncState',
      'orderId',
      'menuItemId',
      'variantId',
      'itemNameSnapshot',
      'variantNameSnapshot',
      'quantity',
      'unitPricePaise',
      'discountAmountPaise',
      'taxAmountPaise',
      'totalAmountPaise',
      'notes',
    });

    // A refund reverses a stored total. It needs no rate of its own.
    expect(
      await columnsOf(database, SqliteTables.refunds),
      isNot(contains('taxRateBasisPoints')),
    );
    // And a held bill still carries only its subtotal: a discount and a rate are applied at
    // settlement, so a bill put aside has neither yet.
    final Set<String> held = await columnsOf(database, SqliteTables.heldBills);
    expect(held, isNot(contains('taxRateBasisPoints')));
    expect(held, isNot(contains('discountType')));
  });

  test('a bill settled before GST existed reads as charging none', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Order order = (await SqliteOrderRepository(
      database: database,
    ).findOrder(orderId)).valueOrNull!;

    // Its own figures, untouched.
    expect(order.orderNumber, '20260210-0004');
    expect(order.status, OrderStatus.completed);
    expect(order.subtotal, Money.parse('450.00'));
    expect(order.totalAmount, Money.parse('450.00'));

    // And the new columns read as what that bill actually charged, which was nothing. Zero
    // here is a fact about the bill, not a stand-in for an unknown.
    expect(order.discountAmount, Money.zero);
    expect(order.taxAmount, Money.zero);
    expect(order.taxRateBasisPoints, 0);
    expect(order.hasDiscount, isFalse);
    expect(order.hasTax, isFalse);

    // The rule is null rather than zero, because "no rule was recorded" is a different fact
    // from "a rule that took off nothing".
    expect(order.discountType, isNull);
    expect(order.discountValue, 0);

    expect(
      GstRate.fromStoredBasisPoints(order.taxRateBasisPoints),
      GstRate.zero,
    );
  });

  test('the legacy bill is not rewritten by the upgrade', () async {
    // Read straight out of the table, so nothing the model does can mask a rewrite.
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final Map<String, Object?> row = (await database.database.query(
      SqliteTables.orders,
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
    )).single;

    expect(row['subtotalPaise'], 45000);
    expect(row['totalAmountPaise'], 45000);
    expect(row['taxAmountPaise'], 0);
    expect(row['taxRateBasisPoints'], 0);
    expect(row['discountType'], isNull);
    expect(row['discountValue'], 0);
    // createdAt and updatedAt are exactly as v8 wrote them: an additive migration touches
    // no row.
    expect(row['createdAt'], legacyBilledAt.millisecondsSinceEpoch);
    expect(row['updatedAt'], legacyBilledAt.millisecondsSinceEpoch);
    expect(row['syncState'], 'synced');
  });

  test('the legacy bill prints with no discount and no tax lines', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SalePrintDocuments documents =
        (await RepositorySalePrintDocumentSource(
          orders: SqliteOrderRepository(database: database),
          payments: SqlitePaymentRepository(database: database),
          kots: SqliteKotRepository(database: database),
          customers: SqliteCustomerRepository(database: database),
          identity: SettingsBusinessIdentitySource(
            settings: SqliteSettingsRepository(database: database),
          ),
        ).forOrder(orderId)).valueOrNull!;

    final CustomerReceiptTotals totals = documents.receipt.totals;

    expect(totals.subtotal, Money.parse('450.00'));
    expect(totals.total, Money.parse('450.00'));
    expect(totals.hasDiscount, isFalse);
    expect(totals.hasTax, isFalse);
    expect(totals.showsTaxableAmount, isFalse);
    // No rule was recorded, so nothing is invented to explain a discount that does not
    // exist.
    expect(totals.discountLabel, isNull);
    expect(totals.taxRate, GstRate.zero);
    // The block still adds up, which is what the source refuses to print without.
    expect(totals.isConsistent, isTrue);
  });

  test('the legacy bill reports with zero discount and zero GST', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteSalesReportRepository reports = SqliteSalesReportRepository(
      database: database,
    );
    final DateRange thatDay = DateRange.day(legacyBilledAt.toLocal());

    final SalesSummary summary = (await reports.loadSummary(thatDay))
        .valueOrNull!;

    expect(summary.billCount, 1);
    expect(summary.subtotal, Money.parse('450.00'));
    expect(summary.discountTotal, Money.zero);
    expect(summary.taxTotal, Money.zero);
    // With nothing taken off, taxable sales are the subtotal.
    expect(summary.taxableSales, Money.parse('450.00'));
    expect(summary.grossSales, Money.parse('450.00'));
    expect(summary.hasTax, isFalse);
    expect(summary.hasDiscounts, isFalse);
    expect(summary.cgstTotal, Money.zero);
    expect(summary.sgstTotal, Money.zero);

    // The bills list reads the new columns too, and they have to come back rather than
    // throw: the query names them explicitly.
    final List<SalesBill> bills = (await reports.loadBills(thatDay))
        .valueOrNull!;
    expect(bills, hasLength(1));
    expect(bills.single.order.taxRateBasisPoints, 0);
    expect(bills.single.order.discountType, isNull);
  });

  test('a bill settled before GST existed can still be refunded', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final SqliteRefundRepository refunds = SqliteRefundRepository(
      database: database,
    );
    final RefundableBill bill = (await refunds.loadRefundable(orderId))
        .valueOrNull!;

    expect(bill.paidAmount, Money.parse('450.00'));
    expect(bill.refundableAmount, Money.parse('450.00'));
    expect(bill.canRefund, isTrue);

    final Refund written = (await refunds.refund(
      RefundRequest.forBill(bill, at: DateTime.utc(2026, 2, 11, 10)),
    )).valueOrNull!;

    // The bill's own total, which carried no tax. Today's rate is nowhere near this.
    expect(written.amount, Money.parse('450.00'));

    // And the legacy tender is still exactly as v8 wrote it.
    final Payment tender = (await SqlitePaymentRepository(
      database: database,
    ).loadForOrder(orderId)).valueOrNull!.single;
    expect(tender.status, PaymentStatus.completed);
    expect(tender.amount, Money.parse('450.00'));
  });

  test('the seeded menu and the kitchen slip survive', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<MenuItem> items = (await SqliteMenuRepository(
      database: database,
    ).loadItems()).valueOrNull!;
    expect(
      items.map((MenuItem item) => item.name),
      contains('Cheese Pizza'),
      reason: 'the seeded menu must not be re-seeded or dropped',
    );

    expect(
      (await SqliteKotRepository(database: database).findKot(kotId))
          .valueOrNull!
          .kotNumber,
      'K20260210-0003',
    );
  });

  test('foreign keys hold across the whole upgraded database', () async {
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final List<Map<String, Object?>> violations = await database.database
        .rawQuery('PRAGMA foreign_key_check');

    expect(violations, isEmpty);
  });

  test('a fresh database and an upgraded one agree on the schema', () async {
    // The guarantee the migration runner exists for: a new terminal and an upgraded one end
    // up with the same tables and the same columns, in the same order.
    final SqliteDatabase upgraded = await TestDatabase.openOnDisk(path);
    addTearDown(upgraded.close);
    final SqliteDatabase fresh = await TestDatabase.openInMemory();
    addTearDown(fresh.close);

    for (final String table in <String>[
      SqliteTables.orders,
      SqliteTables.orderItems,
      SqliteTables.payments,
      SqliteTables.refunds,
      SqliteTables.heldBills,
    ]) {
      expect(
        await columnsOf(upgraded, table),
        await columnsOf(fresh, table),
        reason: '$table differs between a fresh and an upgraded database',
      );
    }
  });

  test('a new bill on the upgraded database carries its rate', () async {
    // The upgraded terminal has to be able to do the new thing, not merely tolerate the old
    // rows. Written straight to the table because building a cart is the checkout tests'
    // job; what is proved here is that the added columns accept a value on a database that
    // was migrated rather than created.
    final SqliteDatabase database = await TestDatabase.openOnDisk(path);
    addTearDown(database.close);

    final int at = DateTime.utc(2026, 2, 12, 12).millisecondsSinceEpoch;
    await database.database.insert(SqliteTables.orders, <String, Object?>{
      'id': 'ord-after-upgrade',
      'createdAt': at,
      'updatedAt': at,
      'isDeleted': 0,
      'syncState': 'pending',
      'orderNumber': '20260212-0001',
      'orderType': 'takeaway',
      'status': 'completed',
      'subtotalPaise': 100000,
      'discountAmountPaise': 10000,
      'taxAmountPaise': 16200,
      'totalAmountPaise': 106200,
      'taxRateBasisPoints': 1800,
      'discountType': 'percentage',
      'discountValue': 1000,
    });

    final Order order = (await SqliteOrderRepository(
      database: database,
    ).findOrder('ord-after-upgrade')).valueOrNull!;

    expect(order.subtotal, Money.parse('1000.00'));
    expect(order.discountAmount, Money.parse('100.00'));
    expect(order.taxableAmount, Money.parse('900.00'));
    expect(order.taxAmount, Money.parse('162.00'));
    expect(order.totalAmount, Money.parse('1062.00'));
    expect(order.taxRateBasisPoints, 1800);
    expect(order.discountType, 'percentage');
    expect(order.discountValue, 1000);
  });
}

/// Builds a database in exactly the state migration v8 left it in.
///
/// The eight shipped migrations are replayed, then a settled bill with its customer, its
/// tender and its kitchen slip is inserted. The rows are written by hand rather than
/// through the repositories on purpose: a repository compiled against the current build
/// would write `taxRateBasisPoints`, and the point is to open a row from before the column
/// existed.
Future<void> _createVersion8Database(
  String path, {
  required String orderId,
  required String paymentId,
  required String kotId,
  required String customerId,
  required DateTime billedAt,
}) async {
  final int at = billedAt.millisecondsSinceEpoch;

  final Database database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 8,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (Database db, int version) async {
        await const M001InitialSchema().migrate(db);
        await const M002SeedMenu().migrate(db);
        await const M003SeedMenuProducts().migrate(db);
        await const M004ScopedMenuOptions().migrate(db);
        await const M005KotOrderSnapshots().migrate(db);
        await const M006RecipesAndStockDeduction().migrate(db);
        await const M007HeldBills().migrate(db);
        await const M008Refunds().migrate(db);

        await db.insert(SqliteTables.customers, <String, Object?>{
          'id': customerId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'name': 'Pre-GST Customer',
          'phone': '9000000077',
        });

        // A bill with no discount and no tax, which is the only kind this build could
        // produce: `BillTotals` had no source for either.
        await db.insert(SqliteTables.orders, <String, Object?>{
          'id': orderId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderNumber': '20260210-0004',
          'orderType': 'takeaway',
          'status': 'completed',
          'customerId': customerId,
          'subtotalPaise': 45000,
          'discountAmountPaise': 0,
          'taxAmountPaise': 0,
          'totalAmountPaise': 45000,
        });

        await db.insert(SqliteTables.orderItems, <String, Object?>{
          'id': 'oit-v8-legacy-1',
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'itemNameSnapshot': 'Pre-GST Pizza',
          'variantNameSnapshot': 'Large',
          'quantity': 3,
          'unitPricePaise': 15000,
          'totalAmountPaise': 45000,
        });

        await db.insert(SqliteTables.payments, <String, Object?>{
          'id': paymentId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'paymentMethod': 'cash',
          'amountPaise': 45000,
          'status': 'completed',
        });

        await db.insert(SqliteTables.kotRecords, <String, Object?>{
          'id': kotId,
          'createdAt': at,
          'updatedAt': at,
          'isDeleted': 0,
          'syncState': 'synced',
          'orderId': orderId,
          'kotNumber': 'K20260210-0003',
          'status': 'completed',
          'orderNumber': '20260210-0004',
          'orderType': 'takeaway',
        });
      },
    ),
  );
  await database.close();
}
