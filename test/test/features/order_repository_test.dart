import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_category.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item_option.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteOrderRepository orders;
  late SqliteMenuRepository menu;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    orders = SqliteOrderRepository(database: database);
    menu = SqliteMenuRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  group('saving and retrieving', () {
    test('an order round-trips with its lines and options', () async {
      final Order order = Fixtures.order(orderNumber: 'T-0001');
      final OrderItem item = Fixtures.orderItem(orderId: order.id);
      final OrderItemOption option = Fixtures.orderItemOption(
        orderItemId: item.id,
      );

      expect(
        (await orders.saveOrder(
          order,
          items: <OrderItem>[item],
          itemOptions: <OrderItemOption>[option],
        )).isOk,
        isTrue,
      );

      final Order? loaded = (await orders.findOrder(order.id)).valueOrNull;
      expect(loaded, isNotNull);
      expect(loaded!.orderNumber, 'T-0001');
      expect(loaded.orderType, OrderType.takeaway);
      expect(loaded.status, OrderStatus.confirmed);
      expect(loaded.totalAmount, Money.parse('210.00'));

      final List<OrderItem> lines = (await orders.loadItems(order.id))
          .valueOrNull!;
      expect(lines, hasLength(1));

      final List<OrderItemOption> options = (await orders.loadItemOptions(
        item.id,
      )).valueOrNull!;
      expect(options, hasLength(1));
      expect(options.first.optionNameSnapshot, 'Extra Cheese');
    });

    test('an order can be found by its printed number', () async {
      final Order order = Fixtures.order(orderNumber: 'T-0042');
      await orders.saveOrder(order);

      final Order? found = (await orders.findOrderByNumber('T-0042'))
          .valueOrNull;
      expect(found?.id, order.id);
    });

    test('a duplicate order number is rejected', () async {
      await orders.saveOrder(Fixtures.order(orderNumber: 'T-0001'));

      final Order duplicate = Fixtures.order(orderNumber: 'T-0001');
      final result = await orders.saveOrder(duplicate);

      // Surfaced as a validation failure rather than a thrown DatabaseException.
      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('a duplicate order number does not destroy the existing bill', () async {
      // INSERT OR REPLACE would have deleted the settled bill to make room for
      // the new one. Refusing the write is the only acceptable outcome.
      final Order settled = Fixtures.order(
        orderNumber: 'T-0099',
        total: '500.00',
        status: OrderStatus.completed,
      );
      await orders.saveOrder(settled);

      await orders.saveOrder(Fixtures.order(orderNumber: 'T-0099'));

      final Order? survivor = (await orders.findOrder(settled.id)).valueOrNull;
      expect(survivor, isNotNull);
      expect(survivor!.totalAmount, Money.parse('500.00'));
      expect(survivor.status, OrderStatus.completed);
      expect((await orders.loadOrders()).valueOrNull, hasLength(1));
    });

    test('re-saving the same order updates it in place', () async {
      final Order order = Fixtures.order(orderNumber: 'T-0098');
      await orders.saveOrder(order);

      await orders.saveOrder(
        order.copyWith(
          status: OrderStatus.completed,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      expect((await orders.loadOrders()).valueOrNull, hasLength(1));
      expect(
        (await orders.findOrder(order.id)).valueOrNull!.status,
        OrderStatus.completed,
      );
    });

    test('saving is atomic: a bad line rolls the whole order back', () async {
      final Order order = Fixtures.order(orderNumber: 'T-0002');
      // Points at an order that is not the one being saved, so the foreign key
      // fails and the header must not survive on its own.
      final OrderItem orphan = Fixtures.orderItem(
        orderId: 'ord-does-not-exist',
      );

      final result = await orders.saveOrder(order, items: <OrderItem>[orphan]);
      expect(result.isErr, isTrue);

      expect((await orders.findOrder(order.id)).valueOrNull, isNull);
    });

    test('every order type is supported', () async {
      for (final OrderType type in OrderType.values) {
        final Order order = Fixtures.order(
          orderNumber: 'T-${type.name}',
          orderType: type,
        );
        expect((await orders.saveOrder(order)).isOk, isTrue);

        final Order? loaded = (await orders.findOrder(order.id)).valueOrNull;
        expect(loaded!.orderType, type);
      }
    });
  });

  group('price and name snapshots', () {
    test(
      'a line keeps the name and price it was sold at when the menu changes',
      () async {
        // This is the property that makes historical bills trustworthy.
        final MenuCategory category = Fixtures.category();
        await menu.saveCategory(category);

        final MenuItem pizza = Fixtures.menuItem(
          categoryId: category.id,
          name: 'Original Name',
          basePrice: '199.00',
        );
        await menu.saveItem(pizza);

        final Order order = Fixtures.order(orderNumber: 'T-0003');
        final OrderItem line = Fixtures.orderItem(
          orderId: order.id,
          menuItemId: pizza.id,
          itemName: 'Original Name',
          variantName: 'Medium',
          quantity: 2,
          unitPrice: '199.00',
          total: '398.00',
        );
        await orders.saveOrder(order, items: <OrderItem>[line]);

        // The menu is renamed and re-priced after the sale.
        await menu.saveItem(
          pizza.copyWith(
            name: 'Renamed And Repriced',
            basePrice: Money.parse('349.00'),
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        final OrderItem reloaded = (await orders.loadItems(order.id))
            .valueOrNull!
            .single;

        expect(reloaded.itemNameSnapshot, 'Original Name');
        expect(reloaded.variantNameSnapshot, 'Medium');
        expect(reloaded.unitPrice, Money.parse('199.00'));
        expect(reloaded.totalAmount, Money.parse('398.00'));
        expect(reloaded.displayName, 'Original Name (Medium)');

        // And the current menu really did change, so the test is meaningful.
        final MenuItem current = (await menu.findItem(pizza.id)).valueOrNull!;
        expect(current.name, 'Renamed And Repriced');
        expect(current.basePrice, Money.parse('349.00'));
      },
    );

    test('a line survives its menu item being deleted', () async {
      final MenuCategory category = Fixtures.category();
      await menu.saveCategory(category);
      final MenuItem discontinued = Fixtures.menuItem(
        categoryId: category.id,
        name: 'Discontinued Item',
      );
      await menu.saveItem(discontinued);

      final Order order = Fixtures.order(orderNumber: 'T-0004');
      await orders.saveOrder(
        order,
        items: <OrderItem>[
          Fixtures.orderItem(
            orderId: order.id,
            menuItemId: discontinued.id,
            itemName: 'Discontinued Item',
          ),
        ],
      );

      await menu.deleteItem(discontinued.id);

      final OrderItem reloaded = (await orders.loadItems(order.id))
          .valueOrNull!
          .single;
      expect(reloaded.itemNameSnapshot, 'Discontinued Item');
    });

    test('an option keeps the price it was charged at', () async {
      final Order order = Fixtures.order(orderNumber: 'T-0005');
      final OrderItem item = Fixtures.orderItem(orderId: order.id);
      final OrderItemOption option = Fixtures.orderItemOption(
        orderItemId: item.id,
        optionName: 'Extra Cheese',
        price: '30.00',
        quantity: 2,
      );

      await orders.saveOrder(
        order,
        items: <OrderItem>[item],
        itemOptions: <OrderItemOption>[option],
      );

      final OrderItemOption reloaded = (await orders.loadItemOptions(item.id))
          .valueOrNull!
          .single;

      expect(reloaded.optionNameSnapshot, 'Extra Cheese');
      expect(reloaded.price, Money.parse('30.00'));
      expect(reloaded.quantity, 2);
      expect(reloaded.totalAmount, Money.parse('60.00'));
    });
  });

  group('order numbers', () {
    test('the first number of the day starts at one', () async {
      final String number = (await orders.nextOrderNumber()).valueOrNull!;
      expect(number, endsWith('-0001'));
      expect(number, matches(RegExp(r'^\d{8}-0001$')));
    });

    test('numbers increment', () async {
      final String first = (await orders.nextOrderNumber()).valueOrNull!;
      await orders.saveOrder(Fixtures.order(orderNumber: first));

      final String second = (await orders.nextOrderNumber()).valueOrNull!;
      expect(second, endsWith('-0002'));
      expect(second, isNot(first));
    });
  });

  group('querying', () {
    test('orders are filtered by status', () async {
      await orders.saveOrder(
        Fixtures.order(orderNumber: 'T-0010', status: OrderStatus.draft),
      );
      await orders.saveOrder(
        Fixtures.order(orderNumber: 'T-0011', status: OrderStatus.completed),
      );

      final List<Order> completed = (await orders.loadOrders(
        status: OrderStatus.completed,
      )).valueOrNull!;
      expect(completed, hasLength(1));
      expect(completed.single.orderNumber, 'T-0011');
    });

    test('orders are filtered by time window', () async {
      await orders.saveOrder(Fixtures.order(orderNumber: 'T-0012'));

      final DateTime now = DateTime.now().toUtc();
      final List<Order> inWindow = (await orders.loadOrders(
        from: now.subtract(const Duration(minutes: 5)),
        to: now.add(const Duration(minutes: 5)),
      )).valueOrNull!;
      expect(inWindow, hasLength(1));

      final List<Order> outOfWindow = (await orders.loadOrders(
        from: now.add(const Duration(days: 1)),
      )).valueOrNull!;
      expect(outOfWindow, isEmpty);
    });

    test('customer history is derived from the orders table', () async {
      final SqliteCustomerRepository customers = SqliteCustomerRepository(
        database: database,
      );
      final Customer customer = Fixtures.customer(phone: '9333300001');
      await customers.save(customer);

      await orders.saveOrder(
        Fixtures.order(orderNumber: 'T-0020', customerId: customer.id),
      );
      await orders.saveOrder(
        Fixtures.order(orderNumber: 'T-0021', customerId: customer.id),
      );
      // Someone else's order, which must not appear.
      await orders.saveOrder(Fixtures.order(orderNumber: 'T-0022'));

      final List<Order> history = (await orders.loadOrdersForCustomer(
        customer.id,
      )).valueOrNull!;

      expect(history, hasLength(2));
      expect(
        history.map((Order o) => o.orderNumber),
        containsAll(<String>['T-0020', 'T-0021']),
      );
    });
  });

  group('status and deletion', () {
    test('status can be advanced through the workflow', () async {
      final Order order = Fixtures.order(
        orderNumber: 'T-0030',
        status: OrderStatus.draft,
      );
      await orders.saveOrder(order);

      for (final OrderStatus next in <OrderStatus>[
        OrderStatus.confirmed,
        OrderStatus.preparing,
        OrderStatus.ready,
        OrderStatus.completed,
      ]) {
        expect((await orders.updateStatus(order.id, next)).isOk, isTrue);
        final Order reloaded = (await orders.findOrder(order.id)).valueOrNull!;
        expect(reloaded.status, next);
      }
    });

    test(
      'a soft-deleted order is hidden but its row and lines remain',
      () async {
        final Order order = Fixtures.order(orderNumber: 'T-0031');
        final OrderItem item = Fixtures.orderItem(orderId: order.id);
        await orders.saveOrder(order, items: <OrderItem>[item]);

        expect((await orders.deleteOrder(order.id)).isOk, isTrue);

        expect((await orders.findOrder(order.id)).valueOrNull, isNull);
        expect((await orders.loadOrders()).valueOrNull, isEmpty);

        // Lines are untouched, so the bill remains auditable.
        expect((await orders.loadItems(order.id)).valueOrNull, hasLength(1));

        final List<Map<String, Object?>> raw = await database.database.query(
          'orders',
          where: 'id = ?',
          whereArgs: <Object?>[order.id],
        );
        expect(raw.single['isDeleted'], 1);
      },
    );
  });
}
