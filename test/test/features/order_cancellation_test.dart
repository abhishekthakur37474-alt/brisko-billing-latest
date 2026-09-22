import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_summary.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/order_inventory_deduction.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_movement_type.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_item.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_record.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/bill_line_snapshot.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_cancellation.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/orders/presentation/controllers/bill_detail_controller.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Cancelling a bill that has already been written.
///
/// ## What these tests are really about
///
/// Cancellation is a status change, and the whole of its correctness is in what the
/// status change does and does not touch. So the assertions come in two halves: the
/// figures that must stop counting the bill, and the record that must survive it
/// completely. Stock gets a group of its own, because the decision there is to do
/// nothing, and a decision to do nothing is only safe if it is held by tests.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteKotRepository kots;
  late SqliteCustomerRepository customers;
  late SqliteSalesReportRepository reports;
  late SqliteInventoryRepository inventory;
  late SqliteInventoryDeductionRepository deductions;

  /// A fixed day, so the report range is arranged rather than waited for.
  final DateTime billedAt = DateTime(2026, 3, 14, 13, 30);
  // The single local day the bills are written on. `DateRange` is built from calendar
  // days rather than a pair of instants, and its instant range is half-open, so this is
  // the same window as `from: 14th, to: 15th`.
  final DateRange thatDay = DateRange.day(DateTime(2026, 3, 14));

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    kots = SqliteKotRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    reports = SqliteSalesReportRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// A settled takeaway bill of ₹210 with a cash tender and a kitchen slip.
  Future<String> settledBill({
    String orderNumber = '20260314-0001',
    String? customerId,
    String? kotNumber = 'K20260314-0001',
  }) {
    return seed.bill(
      orderNumber: orderNumber,
      at: billedAt,
      customerId: customerId,
      kotNumber: kotNumber,
    );
  }

  Future<Order> orderOf(String id) async =>
      (await orders.findOrder(id)).valueOrNull!;

  group('the status change', () {
    test('a settled bill can be cancelled', () async {
      final String id = await settledBill();

      final Result<Order> cancelled = await orders.cancelOrder(id);

      expect(cancelled.isOk, isTrue);
      expect(cancelled.valueOrNull!.status, OrderStatus.cancelled);
      expect((await orderOf(id)).status, OrderStatus.cancelled);
    });

    test('the existing cancelled status is what is used', () async {
      // No second cancellation vocabulary. This is the value reports and customer
      // totals already exclude, which is why nothing else had to change for them.
      expect(OrderCancellation.cancelledStatus, OrderStatus.cancelled);
      expect(OrderStatus.cancelled.countsTowardsSales, isFalse);
      expect(OrderStatus.cancelled.isClosed, isTrue);
    });

    test('a bill that is not there is refused', () async {
      final Result<Order> missing = await orders.cancelOrder('ord-nothing');

      expect(missing.isErr, isTrue);
      expect(missing.failureOrNull, isA<ValidationFailure>());
      expect(
        missing.failureOrNull!.message,
        contains('no longer on this terminal'),
      );
    });

    test('a second cancellation is refused', () async {
      final String id = await settledBill();
      await orders.cancelOrder(id);

      final Result<Order> again = await orders.cancelOrder(id);

      expect(again.isErr, isTrue);
      expect(again.failureOrNull, isA<ValidationFailure>());
      expect(again.failureOrNull!.message, contains('already cancelled'));
    });

    test('two simultaneous cancellations close the bill once', () async {
      final String id = await settledBill();

      final List<Result<Order>> outcomes = await Future.wait(
        <Future<Result<Order>>>[orders.cancelOrder(id), orders.cancelOrder(id)],
      );

      expect(outcomes.where((Result<Order> r) => r.isOk), hasLength(1));
      expect(outcomes.where((Result<Order> r) => r.isErr), hasLength(1));
      expect((await orderOf(id)).status, OrderStatus.cancelled);
    });

    test('a bill still being prepared can be cancelled', () async {
      final String id = await seed.bill(
        orderNumber: '20260314-0002',
        at: billedAt,
        status: OrderStatus.preparing,
      );

      expect((await orders.cancelOrder(id)).isOk, isTrue);
      expect((await orderOf(id)).status, OrderStatus.cancelled);
    });
  });

  group('the record survives', () {
    test('the bill is not deleted', () async {
      final String id = await settledBill();

      await orders.cancelOrder(id);

      final Order order = await orderOf(id);
      expect(order.isDeleted, isFalse);
      expect(order.orderNumber, '20260314-0001');
    });

    test('every stored amount is untouched', () async {
      final String id = await settledBill();
      final Order before = await orderOf(id);

      await orders.cancelOrder(id);

      final Order after = await orderOf(id);
      expect(after.subtotal, before.subtotal);
      expect(after.discountAmount, before.discountAmount);
      expect(after.taxAmount, before.taxAmount);
      expect(after.totalAmount, before.totalAmount);
      expect(after.totalAmount.paise, 21000);
      expect(after.orderType, OrderType.takeaway);
      expect(after.createdAt, before.createdAt);
    });

    test('the lines and their options are all still there', () async {
      final String id = await seed.bill(
        orderNumber: '20260314-0003',
        at: billedAt,
        lines: const <BillLineSpec>[
          BillLineSpec(optionName: 'Extra Cheese', optionPrice: '30.00'),
        ],
      );

      await orders.cancelOrder(id);

      final List<BillLineSnapshot> lines = (await orders.loadBillLines(id))
          .valueOrNull!;
      expect(lines, hasLength(1));
      expect(lines.single.displayName, 'Test Pizza (Medium)');
      expect(lines.single.quantity, 2);
      expect(lines.single.unitPrice.paise, 10000);
      expect(lines.single.lineTotal.paise, 20000);
      expect(lines.single.options, hasLength(1));
      expect(lines.single.options.single.optionNameSnapshot, 'Extra Cheese');
      expect(lines.single.options.single.price.paise, 3000);
    });

    test('the payment stays exactly as it was recorded', () async {
      final String id = await settledBill();

      await orders.cancelOrder(id);

      final List<Payment> tenders = (await payments.loadForOrder(id))
          .valueOrNull!;
      expect(tenders, hasLength(1));
      // The money did arrive. Saying otherwise would be false, and giving it back is a
      // refund, which is not implemented.
      expect(tenders.single.status, PaymentStatus.completed);
      expect(tenders.single.paymentMethod, PaymentMethod.cash);
      expect(tenders.single.amount.paise, 21000);
    });

    test('the bill can still be opened and read', () async {
      final String id = await settledBill();
      await orders.cancelOrder(id);

      final BillDetailController controller = BillDetailController(
        orderId: id,
        orderRepository: orders,
        paymentRepository: payments,
        customerRepository: customers,
        refundRepository: SqliteRefundRepository(database: database),
        printService: TestPrinting.serviceOver(
          database,
          printer: UnconfiguredThermalPrinter(),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();

      expect(controller.hasError, isFalse);
      expect(controller.isMissing, isFalse);
      expect(controller.orderNumber, '20260314-0001');
      expect(controller.order!.status, OrderStatus.cancelled);
      expect(controller.lines, hasLength(1));
      expect(controller.paymentMethod, PaymentMethod.cash);
      // The stored lines still add up to the stored subtotal.
      expect(controller.isConsistent, isTrue);
    });

    test('it stays in the customer history', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await orders.cancelOrder(id);

      final List<Order> history = (await orders.loadOrdersForCustomer(
        customerId,
      )).valueOrNull!;
      expect(history, hasLength(1));
      expect(history.single.id, id);
      expect(history.single.status, OrderStatus.cancelled);
    });
  });

  group('the kitchen slip', () {
    test('is not deleted', () async {
      final String id = await settledBill();

      await orders.cancelOrder(id);

      final List<KotRecord> slips = (await kots.loadForOrder(id)).valueOrNull!;
      expect(slips, hasLength(1));
      expect(slips.single.isDeleted, isFalse);
      expect(slips.single.kotNumber, 'K20260314-0001');
    });

    test('keeps its lines, so what was asked for stays answerable', () async {
      final String id = await settledBill();
      final String kotId = (await kots.loadForOrder(id)).valueOrNull!.single.id;

      await orders.cancelOrder(id);

      final List<KotItem> items = (await kots.loadItems(kotId)).valueOrNull!;
      expect(items, hasLength(1));
      expect(items.single.itemNameSnapshot, 'Test Pizza');
      expect(items.single.quantity, 2);

      // And it is still assembled by the read the printing layer makes.
      final List<KitchenTicket> tickets = (await kots.loadTicketsForOrder(id))
          .valueOrNull!;
      expect(tickets, hasLength(1));
      expect(tickets.single.lines, hasLength(1));
    });

    test('unfinished work is stopped', () async {
      final String id = await settledBill();
      final String kotId = (await kots.loadForOrder(id)).valueOrNull!.single.id;
      expect(
        (await kots.findKot(kotId)).valueOrNull!.status,
        KotStatus.pending,
      );

      await orders.cancelOrder(id);

      // A bill nobody is paying for must not leave food being cooked for it. This is the
      // order-level action `KotStatus.cancelled` exists for.
      expect(
        (await kots.findKot(kotId)).valueOrNull!.status,
        KotStatus.cancelled,
      );
      expect((await kots.loadActiveTickets()).valueOrNull, isEmpty);
    });

    test('work the kitchen already finished is not rewritten', () async {
      final String id = await settledBill();
      final String kotId = (await kots.loadForOrder(id)).valueOrNull!.single.id;
      // The food was made and handed over before the bill was cancelled.
      expect(
        (await kots.updateStatus(kotId, KotStatus.completed)).isOk,
        isTrue,
      );

      await orders.cancelOrder(id);

      // Still completed. Claiming it was cancelled would say the food was never made.
      expect(
        (await kots.findKot(kotId)).valueOrNull!.status,
        KotStatus.completed,
      );
    });

    test('the forward workflow is unchanged', () async {
      // Cancellation adds a terminal state; it does not touch pending → preparing →
      // ready, and the board still refuses anything else.
      expect(KotStatus.pending.nextStep, KotStatus.preparing);
      expect(KotStatus.preparing.nextStep, KotStatus.ready);
      expect(KotStatus.ready.nextStep, isNull);
      expect(KotStatus.pending.canAdvanceTo(KotStatus.cancelled), isFalse);
      expect(KotStatus.ready.canAdvanceTo(KotStatus.cancelled), isFalse);
      expect(OrderCancellation.cancellableKotStatuses, <KotStatus>[
        KotStatus.pending,
        KotStatus.preparing,
        KotStatus.ready,
      ]);
    });

    test('a bill with no slip cancels cleanly', () async {
      final String id = await settledBill(kotNumber: null);

      expect((await orders.cancelOrder(id)).isOk, isTrue);
      expect((await kots.loadForOrder(id)).valueOrNull, isEmpty);
    });
  });

  group('the reports', () {
    test('a cancelled bill contributes nothing to the takings', () async {
      final String id = await settledBill();
      final SalesSummary before = (await reports.loadSummary(thatDay))
          .valueOrNull!;
      expect(before.billCount, 1);
      expect(before.grossSales.paise, 21000);

      await orders.cancelOrder(id);

      final SalesSummary after = (await reports.loadSummary(thatDay))
          .valueOrNull!;
      expect(after.billCount, 0);
      expect(after.itemCount, 0);
      expect(after.grossSales.paise, 0);
      expect(after.subtotal.paise, 0);
      expect(after.taxTotal.paise, 0);
    });

    test('it leaves the bill list', () async {
      final String id = await settledBill();
      expect((await reports.loadBills(thatDay)).valueOrNull, hasLength(1));

      await orders.cancelOrder(id);

      expect((await reports.loadBills(thatDay)).valueOrNull, isEmpty);
    });

    test('its items stop counting towards item sales', () async {
      final String id = await settledBill();
      expect((await reports.loadItemSales(thatDay)).valueOrNull, hasLength(1));

      await orders.cancelOrder(id);

      expect((await reports.loadItemSales(thatDay)).valueOrNull, isEmpty);
    });

    test('its tender leaves the payment mix', () async {
      final String id = await settledBill();
      final PaymentMix before = (await reports.loadPaymentMix(thatDay))
          .valueOrNull!;
      expect(before.amountFor(PaymentMethod.cash).paise, 21000);

      await orders.cancelOrder(id);

      final PaymentMix after = (await reports.loadPaymentMix(thatDay))
          .valueOrNull!;
      // The payment row is still `completed`, and it no longer joins to a settled bill.
      expect(after.amountFor(PaymentMethod.cash).paise, 0);
      expect(after.total.paise, 0);
    });

    test('the other bills of the day are unaffected', () async {
      final String cancelled = await settledBill();
      await settledBill(
        orderNumber: '20260314-0009',
        kotNumber: 'K20260314-0009',
      );

      await orders.cancelOrder(cancelled);

      final SalesSummary summary = (await reports.loadSummary(thatDay))
          .valueOrNull!;
      expect(summary.billCount, 1);
      expect(summary.grossSales.paise, 21000);
    });
  });

  group('the customer', () {
    test('their spend and visit count both stop counting it', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      final CustomerSummary before = (await customers.loadSummary(customerId))
          .valueOrNull!;
      expect(before.completedOrderCount, 1);
      expect(before.totalSpent.paise, 21000);

      await orders.cancelOrder(id);

      final CustomerSummary after = (await customers.loadSummary(customerId))
          .valueOrNull!;
      expect(after.completedOrderCount, 0);
      expect(after.totalSpent.paise, 0);
    });

    test('the directory agrees with the summary', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await orders.cancelOrder(id);

      final CustomerSummary listed =
          (await customers.loadDirectory()).valueOrNull!.single;
      expect(listed.customer.id, customerId);
      // Still a customer, with nothing counted against them.
      expect(listed.completedOrderCount, 0);
      expect(listed.totalSpent.paise, 0);
    });

    test('the customer record itself is untouched', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await orders.cancelOrder(id);

      expect(
        (await customers.findByPhone('9000000001')).valueOrNull!.id,
        customerId,
      );
    });

    test('their other bill still counts', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String cancelled = await settledBill(customerId: customerId);
      await settledBill(
        orderNumber: '20260314-0008',
        customerId: customerId,
        kotNumber: 'K20260314-0008',
      );

      await orders.cancelOrder(cancelled);

      final CustomerSummary after = (await customers.loadSummary(customerId))
          .valueOrNull!;
      expect(after.completedOrderCount, 1);
      expect(after.totalSpent.paise, 21000);
      // Both bills stay in the history.
      expect(
        (await orders.loadOrdersForCustomer(customerId)).valueOrNull,
        hasLength(2),
      );
    });
  });

  group('stock is deliberately left alone', () {
    /// A settled bill whose one line has a recipe, with the stock already deducted.
    ///
    /// Returns the stock item's id. The deduction is run through the production
    /// repository, so the ledger rows are the ones a real sale writes.
    Future<String> settledBillWithDeductedStock() async {
      final InventoryItem cheese = Fixtures.inventoryItem(
        name: 'Cheese',
        currentQuantity: '10',
      );
      expect((await inventory.saveItem(cheese)).isOk, isTrue);

      final String menuItemId =
          (await SqliteOrderRepository(
            database: database,
          ).nextOrderNumber()).isOk
          ? 'item-cheese-pizza'
          : 'item-cheese-pizza';

      // A menu item and a recipe for it, so the deduction has something to resolve.
      final String orderId = await seed.bill(
        orderNumber: '20260314-0100',
        at: billedAt,
        kotNumber: 'K20260314-0100',
        lines: <BillLineSpec>[BillLineSpec(menuItemId: menuItemId)],
      );

      // The recipe is written directly, because the menu item on the bill is a
      // reporting back-reference rather than a seeded row and the recipe table's foreign
      // key needs a real one. Using the seeded menu instead keeps this honest.
      return _deductAgainstSeededMenu(
        database: database,
        deductions: deductions,
        orderId: orderId,
        stockItemId: cheese.id,
      );
    }

    test('a cancellation writes no stock movement', () async {
      final String stockItemId = await settledBillWithDeductedStock();
      final String orderId = (await orders.loadOrders()).valueOrNull!.single.id;
      final List<StockMovement> before = (await inventory.loadMovements(
        stockItemId,
      )).valueOrNull!;
      expect(before.where((StockMovement m) => m.isSale), hasLength(1));

      await orders.cancelOrder(orderId);

      final List<StockMovement> after = (await inventory.loadMovements(
        stockItemId,
      )).valueOrNull!;
      // Not one more row. The decision is recorded on
      // OrderCancellation.reversesInventory, and this is what holds it.
      expect(after, hasLength(before.length));
      expect(
        after.where(
          (StockMovement m) => m.movementType == StockMovementType.adjustment,
        ),
        isEmpty,
        reason: 'no reversal is improvised as an adjustment',
      );
    });

    test('the balance is unchanged by the cancellation', () async {
      final String stockItemId = await settledBillWithDeductedStock();
      final String orderId = (await orders.loadOrders()).valueOrNull!.single.id;
      final int deducted = (await inventory.findItem(stockItemId))
          .valueOrNull!
          .currentQuantityMilli;

      await orders.cancelOrder(orderId);

      expect(
        (await inventory.findItem(stockItemId))
            .valueOrNull!
            .currentQuantityMilli,
        deducted,
        reason: 'stock is neither given back nor taken again',
      );
    });

    test('the original sale movements are left intact', () async {
      final String stockItemId = await settledBillWithDeductedStock();
      final String orderId = (await orders.loadOrders()).valueOrNull!.single.id;

      await orders.cancelOrder(orderId);

      final StockMovement sale = (await inventory.loadMovements(stockItemId))
          .valueOrNull!
          .firstWhere((StockMovement m) => m.isSale);
      expect(sale.isDeleted, isFalse);
      expect(sale.referenceId, orderId);
      // Soft-deleting it would desync the cached balance, which nothing adjusts on
      // delete. The ledger stays the record of what was taken.
      expect(sale.quantityMilli, greaterThan(0));
    });

    test('the deduction record is left intact', () async {
      final String stockItemId = await settledBillWithDeductedStock();
      final String orderId = (await orders.loadOrders()).valueOrNull!.single.id;
      expect(stockItemId, isNotEmpty);

      await orders.cancelOrder(orderId);

      final OrderInventoryDeduction record = (await deductions.findDeduction(
        orderId,
      )).valueOrNull!;
      expect(record.isComplete, isTrue);
      expect(record.movementCount, 1);
      expect(record.isDeleted, isFalse);
    });

    test('the decision is recorded rather than assumed', () async {
      // A named constant so the omission is a statement in the code, not an absence.
      expect(OrderCancellation.reversesInventory, isFalse);
    });
  });
}

/// Configures a recipe against the bill's menu item and deducts for the order.
///
/// Split out so the stock group reads as arrangement plus assertion. Returns the stock
/// item id.
Future<String> _deductAgainstSeededMenu({
  required SqliteDatabase database,
  required SqliteInventoryDeductionRepository deductions,
  required String orderId,
  required String stockItemId,
}) async {
  // The bill's line carries `menuItemId` as a reporting back-reference with no foreign
  // key, but `recipe_ingredients.menuItemId` does have one. So the recipe is attached to
  // a real seeded menu item, and the bill's line is pointed at the same id.
  final List<Map<String, Object?>> items = await database.database.query(
    SqliteTables.menuItems,
    columns: <String>['id'],
    limit: 1,
  );
  final String menuItemId = items.single['id']! as String;

  await database.database.update(
    SqliteTables.orderItems,
    <String, Object?>{'menuItemId': menuItemId},
    where: 'orderId = ?',
    whereArgs: <Object?>[orderId],
  );

  await database.database.insert(
    SqliteTables.recipeIngredients,
    <String, Object?>{
      'id': 'rcp-cancellation-test',
      'createdAt': 0,
      'updatedAt': 0,
      'isDeleted': 0,
      'syncState': 'pending',
      'menuItemId': menuItemId,
      'variantId': null,
      'inventoryItemId': stockItemId,
      // 100 g per unit, so two units take 200 g off a 10 kg shelf.
      'quantityMilli': 100,
    },
  );

  final Result<OrderInventoryDeduction> deducted = await deductions
      .deductForOrder(orderId);
  expect(
    deducted.isOk,
    isTrue,
    reason: 'arrangement failed: ${deducted.failureOrNull?.message}',
  );
  expect(deducted.valueOrNull!.movementCount, 1);

  return stockItemId;
}
