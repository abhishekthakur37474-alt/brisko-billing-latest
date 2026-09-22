import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/auth/domain/services/manager_auth_service.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/presentation/controllers/bill_detail_controller.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Cancelling a bill from its detail view.
///
/// Cancellation is a status change owned by `OrderRepository.cancelOrder`; the controller
/// only reaches it. These tests confirm that the action is offered where it should be, that
/// it changes exactly what the domain says it changes, and that it leaves the money and the
/// lines alone — the same guarantees the repository's own tests hold, checked here through
/// the surface the cashier uses.
void main() {
  setUpAll(TestDatabase.register);

  final DateTime billedAt = DateTime(2026, 9, 13, 13, 30);

  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteCustomerRepository customers;
  late SqliteRefundRepository refunds;
  late SqliteKotRepository kots;
  late PrintService printing;
  late ManagerAuthService managerAuth;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    refunds = SqliteRefundRepository(database: database);
    kots = SqliteKotRepository(database: database);
    printing = TestPrinting.serviceOver(
      database,
      printer: UnconfiguredThermalPrinter(),
    );
    managerAuth = ManagerAuthService(
      settings: SqliteSettingsRepository(database: database),
    );
    await managerAuth.setPassword('1234');
  });

  tearDown(() async {
    await database.close();
  });

  BillDetailController openBill(String orderId) {
    final BillDetailController controller = BillDetailController(
      orderId: orderId,
      orderRepository: orders,
      paymentRepository: payments,
      customerRepository: customers,
      refundRepository: refunds,
      managerAuthService: managerAuth,
      printService: printing,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<String> liveBill({
    String orderNumber = '20260913-0001',
    String? kotNumber = 'K-1',
  }) {
    // A confirmed, unsettled bill with an outstanding kitchen slip: the case a
    // cancellation is actually for.
    return seed.bill(
      orderNumber: orderNumber,
      at: billedAt,
      status: OrderStatus.confirmed,
      kotNumber: kotNumber,
      paymentMethod: null,
    );
  }

  group('when cancel is offered', () {
    test('a live bill can be cancelled', () async {
      final BillDetailController bill = openBill(await liveBill());
      await bill.load();

      expect(bill.canCancel, isTrue);
    });

    test('a completed bill is refunded, not cancelled', () async {
      final String orderId = await seed.bill(
        orderNumber: '20260913-0001',
        at: billedAt,
        status: OrderStatus.completed,
      );
      final BillDetailController bill = openBill(orderId);
      await bill.load();

      expect(bill.canCancel, isFalse);
      // The refund action is the right one for a settled bill.
      expect(bill.canRefund, isTrue);
    });

    test('an already-cancelled bill offers neither cancel nor a lie', () async {
      final String orderId = await liveBill();
      await orders.cancelOrder(orderId);

      final BillDetailController bill = openBill(orderId);
      await bill.load();

      expect(bill.canCancel, isFalse);
      expect(bill.cancelRefusal, 'This bill is already cancelled.');
    });
  });

  group('cancelling', () {
    test('flips the status to cancelled and reloads', () async {
      final String orderId = await liveBill();
      final BillDetailController bill = openBill(orderId);
      await bill.load();

      final bool cancelled = await bill.cancel(password: '1234');

      expect(cancelled, isTrue);
      expect(bill.didCancel, isTrue);
      expect(bill.order!.status, OrderStatus.cancelled);
      // Read back from storage, not just held in memory.
      expect(
        (await orders.findOrder(orderId)).valueOrNull!.status,
        OrderStatus.cancelled,
      );
    });

    test('stops the outstanding kitchen slip', () async {
      final String orderId = await liveBill();
      final BillDetailController bill = openBill(orderId);
      await bill.load();

      await bill.cancel(password: '1234');

      final tickets = (await kots.loadTicketsForOrder(orderId)).valueOrNull!;
      expect(tickets, isNotEmpty);
      expect(tickets.single.status, KotStatus.cancelled);
    });

    test('reverses no payment and rewrites no amount', () async {
      // A confirmed bill that happens to carry a settled tender.
      final String orderId = await seed.bill(
        orderNumber: '20260913-0001',
        at: billedAt,
        status: OrderStatus.confirmed,
        paymentMethod: null,
      );
      await payments.record(
        Fixtures.payment(
          orderId: orderId,
          method: PaymentMethod.cash,
          amount: '210.00',
          status: PaymentStatus.completed,
          createdAt: billedAt,
        ),
      );

      final int before = (await payments.loadForOrder(orderId))
          .valueOrNull!
          .length;
      final Money totalBefore = (await orders.findOrder(orderId))
          .valueOrNull!
          .totalAmount;

      final BillDetailController bill = openBill(orderId);
      await bill.load();
      await bill.cancel(password: '1234');

      final tenders = (await payments.loadForOrder(orderId)).valueOrNull!;
      expect(tenders, hasLength(before));
      expect(tenders.single.status, PaymentStatus.completed);
      expect(
        (await orders.findOrder(orderId)).valueOrNull!.totalAmount,
        totalBefore,
      );
    });

    test('a second cancellation is refused, not repeated', () async {
      final String orderId = await liveBill();
      await orders.cancelOrder(orderId);

      final BillDetailController bill = openBill(orderId);
      await bill.load();

      // The action is not even offered, so a direct call stands in for a race.
      final bool cancelledAgain = await bill.cancel(password: '1234');
      expect(cancelledAgain, isFalse);
      expect(bill.hasCancelError, isTrue);
      expect(bill.cancelError, contains('already cancelled'));
    });
  });
}
