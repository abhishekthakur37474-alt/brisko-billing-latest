import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item_option.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';

import 'fixtures.dart';

/// One line to write onto a seeded bill.
///
/// The amounts are decimal strings because that is how a person writes a price when
/// arranging a test. They are parsed by [Fixtures] into integer paise before anything
/// touches the database, and no amount is ever compared as text.
class BillLineSpec {
  const BillLineSpec({
    this.itemName = 'Test Pizza',
    this.variantName = 'Medium',
    this.quantity = 2,
    this.unitPrice = '100.00',
    this.total = '200.00',
    this.menuItemId,
    this.optionName,
    this.optionPrice = '0.00',
  });

  final String itemName;
  final String? variantName;
  final int quantity;
  final String unitPrice;
  final String total;

  /// Reporting back-reference. Left `null` unless a test is specifically about what
  /// happens to a bill when the menu item behind it changes.
  final String? menuItemId;

  /// A customisation on the line, or `null` for none.
  final String? optionName;
  final String optionPrice;
}

/// Writes settled bills into a test database, through the real repositories.
///
/// ## Why the real repositories
///
/// The reports are aggregate SQL over the persisted tables, so a test that seeded rows
/// through a fake would be testing nothing. Every bill here is written by
/// `SqliteOrderRepository`, `SqlitePaymentRepository` and the rest — the same code
/// settlement uses — so the rows have the shape production rows have, foreign keys and
/// all.
///
/// ## Dates
///
/// Every method takes the instant to write, because the whole point of the reports tests
/// is arranging bills on particular days. Nothing here reads a clock.
class SeededSales {
  SeededSales(SqliteDatabase database)
    : orders = SqliteOrderRepository(database: database),
      payments = SqlitePaymentRepository(database: database),
      kots = SqliteKotRepository(database: database),
      customers = SqliteCustomerRepository(database: database);

  final SqliteOrderRepository orders;
  final SqlitePaymentRepository payments;
  final SqliteKotRepository kots;
  final SqliteCustomerRepository customers;

  /// Creates a customer and returns their id.
  Future<String> customer({
    String phone = '9000000001',
    String? name = 'Test Customer',
  }) async {
    final String id = EntityId.generate(prefix: 'cus');
    _expectOk(
      await customers.save(Fixtures.customer(id: id, phone: phone, name: name)),
    );
    return id;
  }

  /// Writes one bill with its lines, its tender and optionally its kitchen slip.
  ///
  /// Returns the order id. Defaults describe an ordinary settled takeaway paid in cash:
  /// a ₹200 line, ₹10 tax, ₹210 collected.
  ///
  /// Pass [paymentMethod] as `null` for a bill with no tender recorded, and
  /// [paymentStatus] to record one that has not landed — both of which the reports have
  /// to treat differently from money in.
  Future<String> bill({
    required String orderNumber,
    required DateTime at,
    OrderStatus status = OrderStatus.completed,
    OrderType orderType = OrderType.takeaway,
    String subtotal = '200.00',
    String discount = '0.00',
    String tax = '10.00',
    String total = '210.00',
    String? customerId,
    String? customerName,
    String? kotNumber,
    PaymentMethod? paymentMethod = PaymentMethod.cash,
    PaymentStatus paymentStatus = PaymentStatus.completed,
    String? paymentAmount,
    List<BillLineSpec> lines = const <BillLineSpec>[BillLineSpec()],
    String? notes,
  }) async {
    final String orderId = EntityId.generate(prefix: 'ord');

    final Order order = Fixtures.order(
      id: orderId,
      orderNumber: orderNumber,
      orderType: orderType,
      status: status,
      customerId: customerId,
      customerName: customerName,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      total: total,
      notes: notes,
      createdAt: at,
    );

    final List<OrderItem> items = <OrderItem>[];
    final List<OrderItemOption> options = <OrderItemOption>[];

    for (final BillLineSpec line in lines) {
      final String itemId = EntityId.generate(prefix: 'oit');
      items.add(
        Fixtures.orderItem(
          id: itemId,
          orderId: orderId,
          menuItemId: line.menuItemId,
          itemName: line.itemName,
          variantName: line.variantName,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          total: line.total,
          createdAt: at,
        ),
      );
      if (line.optionName != null) {
        options.add(
          Fixtures.orderItemOption(
            orderItemId: itemId,
            optionName: line.optionName!,
            price: line.optionPrice,
            quantity: line.quantity,
            createdAt: at,
          ),
        );
      }
    }

    _expectOk(
      await orders.saveOrder(order, items: items, itemOptions: options),
    );

    if (paymentMethod != null) {
      _expectOk(
        await payments.record(
          Fixtures.payment(
            orderId: orderId,
            method: paymentMethod,
            amount: paymentAmount ?? total,
            status: paymentStatus,
            createdAt: at,
          ),
        ),
      );
    }

    if (kotNumber != null) {
      final String kotId = EntityId.generate(prefix: 'kot');
      _expectOk(
        await kots.createKot(
          Fixtures.kotRecord(
            id: kotId,
            orderId: orderId,
            orderNumber: orderNumber,
            kotNumber: kotNumber,
            orderType: orderType,
            createdAt: at,
          ),
          <KotItem>[
            Fixtures.kotItem(
              kotId: kotId,
              orderItemId: items.first.id,
              itemName: items.first.itemNameSnapshot,
              variantName: items.first.variantNameSnapshot,
              quantity: items.first.quantity,
            ),
          ],
        ),
      );
    }

    return orderId;
  }

  /// Fails the arrangement loudly rather than letting a test assert against a database
  /// that was never written to.
  static void _expectOk(Result<void> result) {
    if (result.isErr) {
      throw StateError(
        'Test arrangement failed: ${result.failureOrNull!.message}',
      );
    }
  }
}
