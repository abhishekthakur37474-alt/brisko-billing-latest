import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item_option.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';

/// Settlement against the real database and the real seeded menu.
///
/// The carts here are assembled through [BillingController] over
/// [SqliteMenuRepository], so every price that ends up in an assertion travelled the
/// production path from the seed. Nothing is stubbed, and the transaction under test is
/// the one the application runs.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// A Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  Future<Cart> pizzaCart({int quantity = 1}) =>
      SeededCart.mediumCheesePizzaWithExtraCheese(menu, quantity: quantity);

  BillSettlement settlementFor(
    Cart cart, {
    OrderType orderType = OrderType.takeaway,
    PaymentMethod method = PaymentMethod.cash,
    String? customerName,
    String? customerPhone,
    String? reference,
    String? notes,
  }) => BillSettlement.fromCart(
    cart: cart,
    orderType: orderType,
    paymentMethod: method,
    customerName: customerName,
    customerPhone: customerPhone,
    reference: reference,
    notes: notes,
  );

  /// Rows physically present, ignoring the soft-delete filter the repositories apply.
  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  group('settling a bill', () {
    test(
      'writes the order, its lines, their options and the payment',
      () async {
        final Cart cart = await pizzaCart();

        final Result<Order> result = await checkout.settle(settlementFor(cart));

        expect(result.isOk, isTrue);
        final Order order = result.valueOrNull!;

        expect(order.orderNumber, matches(RegExp(r'^\d{8}-0001$')));
        expect(order.status, OrderStatus.completed);
        expect(order.orderType, OrderType.takeaway);
        expect(order.subtotal, Money.parse('320'));
        expect(order.discountAmount, Money.zero);
        expect(order.taxAmount, Money.zero);
        expect(order.totalAmount, Money.parse('320'));
        expect(order.customerId, isNull);
        expect(order.customerName, isNull);

        // Read back through the order repository, not from the value returned.
        final Order stored = (await orders.findOrder(order.id)).valueOrNull!;
        expect(stored.orderNumber, order.orderNumber);
        expect(stored.totalAmount, Money.parse('320'));
        expect(stored.status, OrderStatus.completed);

        final List<OrderItem> lines = (await orders.loadItems(order.id))
            .valueOrNull!;
        expect(lines, hasLength(1));
        expect(lines.single.itemNameSnapshot, 'Cheese Pizza');
        expect(lines.single.variantNameSnapshot, 'Medium');
        expect(lines.single.displayName, 'Cheese Pizza (Medium)');
        expect(lines.single.quantity, 1);
        expect(lines.single.unitPrice, Money.parse('320'));
        expect(lines.single.totalAmount, Money.parse('320'));
        expect(lines.single.menuItemId, isNotNull);
        expect(lines.single.variantId, isNotNull);

        final List<OrderItemOption> options = (await orders.loadItemOptions(
          lines.single.id,
        )).valueOrNull!;
        expect(options, hasLength(1));
        expect(options.single.optionNameSnapshot, 'Extra Cheese');
        expect(options.single.price, Money.parse('70'));
        expect(options.single.quantity, 1);
        expect(options.single.optionId, isNotNull);

        final List<Payment> tendered = (await payments.loadForOrder(order.id))
            .valueOrNull!;
        expect(tendered, hasLength(1));
        expect(tendered.single.paymentMethod, PaymentMethod.cash);
        expect(tendered.single.amount, Money.parse('320'));
        expect(tendered.single.status, PaymentStatus.completed);

        expect(
          (await payments.settledTotalForOrder(order.id)).valueOrNull,
          Money.parse('320'),
        );
      },
    );

    test('a name without a phone is stored on the bill', () async {
      final Cart cart = await pizzaCart();

      final Result<Order> result = await checkout.settle(
        settlementFor(cart, customerName: 'Ravi'),
      );

      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      final Order order = result.valueOrNull!;
      expect(order.customerId, isNull);
      expect(order.customerName, 'Ravi');
      expect(await rowCount('customers'), 0);

      final Order stored = (await orders.findOrder(order.id)).valueOrNull!;
      expect(stored.customerName, 'Ravi');
    });

    test('a multi-line bill totals exactly and keeps its line order', () async {
      final BillingController billing = await SeededCart.controller(menu);
      addTearDown(billing.dispose);

      // (250 + 70) x 2 = 640
      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
        options: <String>['Extra Cheese'],
        quantity: 2,
      );
      // 400
      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Large',
      );
      // 70 + 10 = 80
      await SeededCart.add(
        billing,
        category: 'SIDE ORDER',
        item: 'French Fries',
        options: <String>['Ketchup'],
      );

      expect(billing.subtotal, Money.parse('1120'));

      final Order order = (await checkout.settle(settlementFor(billing.cart)))
          .valueOrNull!;

      expect(order.totalAmount, Money.parse('1120'));
      expect(order.totalAmount.paise, 112000);

      final List<OrderItem> lines = (await orders.loadItems(order.id))
          .valueOrNull!;
      expect(lines.map((OrderItem line) => line.displayName), <String>[
        'Cheese Pizza (Medium)',
        'Cheese Pizza (Large)',
        'French Fries',
      ]);
      expect(
        Money.sum(lines.map((OrderItem line) => line.totalAmount)),
        Money.parse('1120'),
      );

      expect(
        (await payments.settledTotalForOrder(order.id)).valueOrNull,
        Money.parse('1120'),
      );
    });

    test('an option row carries the line quantity and reconciles', () async {
      final Order order = (await checkout.settle(
        settlementFor(await pizzaCart(quantity: 2)),
      )).valueOrNull!;

      final OrderItem line = (await orders.loadItems(order.id))
          .valueOrNull!
          .single;
      final OrderItemOption option = (await orders.loadItemOptions(line.id))
          .valueOrNull!
          .single;

      expect(line.quantity, 2);
      expect(line.totalAmount, Money.parse('640'));
      expect(option.quantity, 2);
      expect(option.totalAmount, Money.parse('140'));
      // Base price times quantity, plus the option rows, is the line total.
      expect(Money.parse('250') * 2 + option.totalAmount, line.totalAmount);
    });

    test('every payment method settles', () async {
      for (final PaymentMethod method in PaymentMethod.values) {
        final Order order = (await checkout.settle(
          settlementFor(
            await pizzaCart(),
            method: method,
            reference: method == PaymentMethod.cash
                ? null
                : 'REF-${method.name}',
          ),
        )).valueOrNull!;

        final Payment payment = (await payments.loadForOrder(order.id))
            .valueOrNull!
            .single;

        expect(payment.paymentMethod, method, reason: method.name);
        expect(payment.amount, Money.parse('320'), reason: method.name);
        expect(payment.status, PaymentStatus.completed, reason: method.name);
        expect(
          payment.reference,
          method == PaymentMethod.cash ? isNull : 'REF-${method.name}',
          reason: method.name,
        );
      }

      expect(await rowCount('orders'), PaymentMethod.values.length);
    });

    test('every order type settles', () async {
      for (final OrderType type in OrderType.values) {
        final Order order = (await checkout.settle(
          settlementFor(await pizzaCart(), orderType: type),
        )).valueOrNull!;

        expect(order.orderType, type, reason: type.name);
        expect(
          (await orders.findOrder(order.id)).valueOrNull!.orderType,
          type,
          reason: type.name,
        );
      }
    });

    test('a note is written onto the bill', () async {
      final Order order = (await checkout.settle(
        settlementFor(await pizzaCart(), notes: 'Cut into eight'),
      )).valueOrNull!;

      expect(
        (await orders.findOrder(order.id)).valueOrNull!.notes,
        'Cut into eight',
      );
    });

    test('order numbers run in sequence for the day', () async {
      final Order first = (await checkout.settle(
        settlementFor(await pizzaCart()),
      )).valueOrNull!;
      final Order second = (await checkout.settle(
        settlementFor(await pizzaCart()),
      )).valueOrNull!;
      final Order third = (await checkout.settle(
        settlementFor(await pizzaCart()),
      )).valueOrNull!;

      expect(first.orderNumber, endsWith('-0001'));
      expect(second.orderNumber, endsWith('-0002'));
      expect(third.orderNumber, endsWith('-0003'));
      expect(<String>{
        first.orderNumber,
        second.orderNumber,
        third.orderNumber,
      }, hasLength(3));

      // And the number the order repository would quote next agrees.
      expect((await orders.nextOrderNumber()).valueOrNull, endsWith('-0004'));
    });

    test('a settled bill is findable by its number', () async {
      final Order order = (await checkout.settle(
        settlementFor(await pizzaCart()),
      )).valueOrNull!;

      final Order found = (await orders.findOrderByNumber(order.orderNumber))
          .valueOrNull!;

      expect(found.id, order.id);
    });
  });

  group('refusing a bill', () {
    test('an empty cart cannot be settled', () async {
      final Result<Order> result = await checkout.settle(
        settlementFor(const Cart.empty()),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await rowCount('orders'), 0);
      expect(await rowCount('payments'), 0);
    });

    test('a payment that disagrees with the total is refused', () async {
      final BillSettlement honest = settlementFor(await pizzaCart());
      final BillSettlement tampered = BillSettlement(
        orderId: honest.orderId,
        orderType: honest.orderType,
        totals: honest.totals,
        items: honest.items,
        itemOptions: honest.itemOptions,
        // ₹300 against a ₹320 bill. The schema cannot see this; settlement must.
        payment: honest.payment.copyWith(amount: Money.parse('300')),
        createdAt: honest.createdAt,
      );

      final Result<Order> result = await checkout.settle(tampered);

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await rowCount('orders'), 0);
      expect(await rowCount('payments'), 0);
    });

    test('settling the same bill twice is refused', () async {
      final BillSettlement settlement = settlementFor(await pizzaCart());

      final Result<Order> first = await checkout.settle(settlement);
      final Result<Order> second = await checkout.settle(settlement);

      expect(first.isOk, isTrue);
      expect(second.isErr, isTrue);
      expect(second.failureOrNull, isA<ValidationFailure>());
      expect(second.failureOrNull!.message, contains('already been settled'));

      // Exactly one bill and one payment, and the number the customer was given.
      expect(await rowCount('orders'), 1);
      expect(await rowCount('order_items'), 1);
      expect(await rowCount('order_item_options'), 1);
      expect(await rowCount('payments'), 1);
      expect(
        (await orders.findOrder(settlement.orderId)).valueOrNull!.orderNumber,
        first.valueOrNull!.orderNumber,
      );
      expect(
        (await payments.settledTotalForOrder(settlement.orderId)).valueOrNull,
        Money.parse('320'),
      );
    });

    test('two submissions racing cannot both land', () async {
      final BillSettlement settlement = settlementFor(await pizzaCart());

      // Started together, without awaiting the first.
      final List<Result<Order>> results = await Future.wait<Result<Order>>(
        <Future<Result<Order>>>[
          checkout.settle(settlement),
          checkout.settle(settlement),
        ],
      );

      expect(results.where((Result<Order> r) => r.isOk), hasLength(1));
      expect(results.where((Result<Order> r) => r.isErr), hasLength(1));
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
    });
  });

  group('atomicity', () {
    test(
      'a line pointing at another order rolls the whole bill back',
      () async {
        final BillSettlement honest = settlementFor(await pizzaCart());
        final BillSettlement broken = BillSettlement(
          orderId: honest.orderId,
          orderType: honest.orderType,
          totals: honest.totals,
          // The foreign key on order_items.orderId cannot be satisfied.
          items: <OrderItem>[
            honest.items.single.copyWith(updatedAt: honest.createdAt),
            _orphanLine(honest),
          ],
          itemOptions: honest.itemOptions,
          payment: honest.payment,
          createdAt: honest.createdAt,
        );

        final Result<Order> result = await checkout.settle(broken);

        expect(result.isErr, isTrue);
        // Nothing at all: not the order, not the good line, not the payment.
        expect(await rowCount('orders'), 0);
        expect(await rowCount('order_items'), 0);
        expect(await rowCount('order_item_options'), 0);
        expect(await rowCount('payments'), 0);
        expect((await orders.findOrder(honest.orderId)).valueOrNull, isNull);
      },
    );

    test('an option pointing at no line rolls the whole bill back', () async {
      final BillSettlement honest = settlementFor(await pizzaCart());
      final BillSettlement broken = BillSettlement(
        orderId: honest.orderId,
        orderType: honest.orderType,
        totals: honest.totals,
        items: honest.items,
        itemOptions: <OrderItemOption>[
          OrderItemOption(
            id: 'oio-orphan',
            orderItemId: 'oit-does-not-exist',
            optionNameSnapshot: 'Extra Cheese',
            price: Money.parse('70'),
            createdAt: honest.createdAt,
            updatedAt: honest.createdAt,
          ),
        ],
        payment: honest.payment,
        createdAt: honest.createdAt,
      );

      final Result<Order> result = await checkout.settle(broken);

      expect(result.isErr, isTrue);
      expect(await rowCount('orders'), 0);
      expect(await rowCount('order_items'), 0);
      expect(await rowCount('payments'), 0);
    });

    test('a payment pointing at no order rolls the whole bill back', () async {
      final BillSettlement honest = settlementFor(await pizzaCart());
      final BillSettlement broken = BillSettlement(
        orderId: honest.orderId,
        orderType: honest.orderType,
        totals: honest.totals,
        items: honest.items,
        itemOptions: honest.itemOptions,
        // Balanced, so it passes the money check and reaches the insert.
        payment: Payment(
          id: honest.payment.id,
          orderId: 'ord-does-not-exist',
          paymentMethod: PaymentMethod.cash,
          amount: honest.totals.total,
          status: PaymentStatus.completed,
          createdAt: honest.createdAt,
          updatedAt: honest.createdAt,
        ),
        createdAt: honest.createdAt,
      );

      final Result<Order> result = await checkout.settle(broken);

      expect(result.isErr, isTrue);
      // The order and its lines were inserted before the payment failed, and the
      // rollback took them with it. This is the case that would otherwise leave a
      // bill looking unpaid.
      expect(await rowCount('orders'), 0);
      expect(await rowCount('order_items'), 0);
      expect(await rowCount('order_item_options'), 0);
      expect(await rowCount('payments'), 0);
    });

    test('a failed settlement consumes no order number', () async {
      final BillSettlement honest = settlementFor(await pizzaCart());
      final BillSettlement broken = BillSettlement(
        orderId: honest.orderId,
        orderType: honest.orderType,
        totals: honest.totals,
        items: honest.items,
        itemOptions: honest.itemOptions,
        payment: honest.payment.copyWith(amount: Money.parse('1')),
        createdAt: honest.createdAt,
      );

      expect((await checkout.settle(broken)).isErr, isTrue);

      // The next real bill is still the first of the day.
      final Order order = (await checkout.settle(
        settlementFor(await pizzaCart()),
      )).valueOrNull!;
      expect(order.orderNumber, endsWith('-0001'));
    });

    test('a retry after a failure settles the same bill once', () async {
      final Cart cart = await pizzaCart();

      // First attempt fails for a reason outside the bill: the database is gone.
      await database.close();
      expect((await checkout.settle(settlementFor(cart))).isErr, isTrue);

      // The cashier retries on a working terminal with the same bill.
      database = await TestDatabase.openInMemory();
      checkout = SqliteCheckoutRepository(database: database);
      orders = SqliteOrderRepository(database: database);

      final BillSettlement settlement = settlementFor(cart);
      expect((await checkout.settle(settlement)).isOk, isTrue);
      expect((await checkout.settle(settlement)).isErr, isTrue);
      expect(await rowCount('orders'), 1);
    });
  });

  group('history does not follow the menu', () {
    test('re-pricing the menu afterwards leaves the bill alone', () async {
      final Cart cart = await pizzaCart();
      final Order order = (await checkout.settle(settlementFor(cart)))
          .valueOrNull!;

      // The owner raises the Medium price and the Extra Cheese price.
      final MenuItem pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem item) => item.name == 'Cheese Pizza',
      );
      final MenuItemVariant medium = (await menu.loadVariants(pizza.id))
          .valueOrNull!
          .firstWhere((MenuItemVariant v) => v.name == 'Medium');
      final DateTime now = DateTime.now().toUtc();

      await menu.saveVariant(
        medium.copyWith(price: Money.parse('999'), updatedAt: now),
      );
      await menu.saveItem(
        pizza.copyWith(name: 'Renamed Pizza', updatedAt: now),
      );

      // The menu really moved.
      expect(
        (await menu.loadVariants(pizza.id)).valueOrNull!
            .firstWhere((MenuItemVariant v) => v.id == medium.id)
            .price,
        Money.parse('999'),
      );

      // The bill did not.
      final OrderItem line = (await orders.loadItems(order.id))
          .valueOrNull!
          .single;
      expect(line.itemNameSnapshot, 'Cheese Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.unitPrice, Money.parse('320'));
      expect(line.totalAmount, Money.parse('320'));
      expect(
        (await orders.findOrder(order.id)).valueOrNull!.totalAmount,
        Money.parse('320'),
      );
    });

    test('an item deleted before checkout still settles', () async {
      final BillingController billing = await SeededCart.controller(menu);
      addTearDown(billing.dispose);
      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
        options: <String>['Extra Cheese'],
      );

      final MenuItem pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem item) => item.name == 'Cheese Pizza',
      );
      expect((await menu.deleteItem(pizza.id)).isOk, isTrue);
      expect((await menu.findItem(pizza.id)).valueOrNull, isNull);

      // order_items.menuItemId deliberately carries no foreign key, so a
      // discontinued product cannot block or orphan a sale.
      final Result<Order> result = await checkout.settle(
        settlementFor(billing.cart),
      );

      expect(result.isOk, isTrue);
      final OrderItem line = (await orders.loadItems(result.valueOrNull!.id))
          .valueOrNull!
          .single;
      expect(line.menuItemId, pizza.id);
      expect(line.itemNameSnapshot, 'Cheese Pizza');
      expect(line.unitPrice, Money.parse('320'));
    });

    test('an item marked unavailable before checkout still settles', () async {
      final BillingController billing = await SeededCart.controller(menu);
      addTearDown(billing.dispose);
      await SeededCart.add(
        billing,
        category: 'SIDE ORDER',
        item: 'French Fries',
        options: <String>['Ketchup'],
      );

      final MenuItem fries = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem item) => item.name == 'French Fries',
      );
      await menu.saveItem(
        fries.copyWith(isAvailable: false, updatedAt: DateTime.now().toUtc()),
      );

      final Result<Order> result = await checkout.settle(
        settlementFor(billing.cart),
      );

      expect(result.isOk, isTrue);
      expect(result.valueOrNull!.totalAmount, Money.parse('80'));
    });
  });

  group('failures reach the caller as values', () {
    test('a closed database is a failure, not an exception', () async {
      final Cart cart = await pizzaCart();
      await database.close();

      final Result<Order> result = await checkout.settle(settlementFor(cart));

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<AppFailure>());
      expect(result.failureOrNull!.message, isNotEmpty);
    });
  });
}

/// A line that belongs to an order which does not exist.
OrderItem _orphanLine(BillSettlement settlement) {
  return OrderItem(
    id: 'oit-orphan',
    orderId: 'ord-does-not-exist',
    itemNameSnapshot: 'Orphan',
    quantity: 1,
    unitPrice: Money.zero,
    totalAmount: Money.zero,
    createdAt: settlement.createdAt,
    updatedAt: settlement.createdAt,
  );
}
