import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_summary.dart';
import 'package:brisko_billing/features/customers/presentation/controllers/customer_directory_controller.dart';
import 'package:brisko_billing/features/customers/presentation/controllers/customer_history_controller.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/bill_line_snapshot.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/orders/presentation/controllers/bill_detail_controller.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Customer order history, over the real database and the real settlement path.
///
/// Every bill in this file is created by settling a cart through
/// [SqliteCheckoutRepository], so what the history reads back is what a cashier's sale
/// actually wrote. Nothing is inserted by hand into `orders`, because a hand-written row
/// would not prove that the snapshots the history depends on are being taken.
///
/// Everything here runs against a local in-memory SQLite database with no network of any
/// kind available, which is the offline-first guarantee this step has to keep.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// Settles a Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320 each.
  Future<Order> sellPizza({
    String? customerPhone,
    int quantity = 1,
    OrderType orderType = OrderType.takeaway,
    PaymentMethod paymentMethod = PaymentMethod.cash,
  }) async {
    final Result<Order> settled = await checkout.settle(
      BillSettlement.fromCart(
        cart: await SeededCart.mediumCheesePizzaWithExtraCheese(
          menu,
          quantity: quantity,
        ),
        orderType: orderType,
        paymentMethod: paymentMethod,
        customerPhone: customerPhone,
      ),
    );
    expect(settled.isOk, isTrue, reason: settled.failureOrNull?.message);
    return settled.valueOrNull!;
  }

  Future<Customer> customerFor(String phone) async {
    final Customer? found = (await customers.findByPhone(phone)).valueOrNull;
    expect(found, isNotNull, reason: 'No customer on file for $phone');
    return found!;
  }

  Future<CustomerHistoryController> historyFor(String customerId) async {
    final CustomerHistoryController controller = CustomerHistoryController(
      customerId: customerId,
      customerRepository: customers,
      orderRepository: orders,
      paymentRepository: payments,
    );
    addTearDown(controller.dispose);
    await controller.load();
    return controller;
  }

  Future<CustomerDirectoryController> directory({String? query}) async {
    final CustomerDirectoryController controller = CustomerDirectoryController(
      customerRepository: customers,
    );
    addTearDown(controller.dispose);
    if (query != null) {
      await controller.search(query);
    } else {
      await controller.load();
    }
    return controller;
  }

  Future<BillDetailController> billDetail(String orderId) async {
    final BillDetailController controller = BillDetailController(
      orderId: orderId,
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
    return controller;
  }

  Future<MenuItem> cheesePizza() async {
    return (await menu.loadItems()).valueOrNull!.firstWhere(
      (MenuItem item) => item.name == 'Cheese Pizza',
    );
  }

  // -------------------------------------------------------------- the directory ---

  group('the customer directory', () {
    test('an outlet that has taken no numbers has no customers', () async {
      final CustomerDirectoryController controller = await directory();

      expect(controller.hasLoaded, isTrue);
      expect(controller.hasError, isFalse);
      expect(controller.results, isEmpty);
      expect(controller.isEmpty, isTrue);
      expect(controller.isEmptyDirectory, isTrue);
    });

    test('a bill with a number puts the customer on the list', () async {
      await sellPizza(customerPhone: '9000000101');

      final CustomerDirectoryController controller = await directory();

      final CustomerSummary summary = controller.results.single;
      expect(summary.phone, '9000000101');
      expect(summary.completedOrderCount, 1);
      expect(summary.totalSpent, Money.parse('320'));
      expect(summary.lastOrderAt, isNotNull);
    });

    test('a walk-in bill puts nobody on the list', () async {
      await sellPizza();

      final CustomerDirectoryController controller = await directory();

      expect(controller.results, isEmpty);
      expect(controller.isEmptyDirectory, isTrue);
    });

    test('the order count is correct across several bills', () async {
      await sellPizza(customerPhone: '9000000102');
      await sellPizza(customerPhone: '9000000102');
      await sellPizza(customerPhone: '9000000102', quantity: 2);

      final CustomerSummary summary = (await directory()).results.single;

      expect(summary.completedOrderCount, 3);
      // 320 + 320 + 640.
      expect(summary.totalSpent, Money.parse('1280'));
      expect(summary.hasOrders, isTrue);
    });

    test('the total spent is the exact sum of the stored totals', () async {
      await sellPizza(customerPhone: '9000000103', quantity: 3);
      await sellPizza(customerPhone: '9000000103');

      final CustomerSummary summary = (await directory()).results.single;

      // 960 + 320, in paise, with no rounding anywhere.
      expect(summary.totalSpent.paise, 128000);
      expect(summary.totalSpent, Money.fromPaise(128000));
      expect(summary.averageOrderValue, Money.parse('640'));
    });

    test('search finds a customer by their whole number', () async {
      await sellPizza(customerPhone: '9000000104');
      await sellPizza(customerPhone: '9876500104');

      final CustomerDirectoryController controller = await directory(
        query: '9000000104',
      );

      expect(controller.results.single.phone, '9000000104');
      expect(controller.hasQuery, isTrue);
    });

    test('search narrows on part of a number', () async {
      await sellPizza(customerPhone: '9000000105');
      await sellPizza(customerPhone: '9876500105');

      expect((await directory(query: '90000')).results, hasLength(1));
      // A fragment both share.
      expect((await directory(query: '00105')).results, hasLength(2));
    });

    test('search ignores the punctuation of a pasted number', () async {
      await sellPizza(customerPhone: '9000000106');

      expect((await directory(query: '+91 90000 00106')).results, hasLength(1));
      expect((await directory(query: '90000-00106')).results, hasLength(1));
    });

    test('a number nobody has used matches nothing, honestly', () async {
      await sellPizza(customerPhone: '9000000107');

      final CustomerDirectoryController controller = await directory(
        query: '9000000199',
      );

      expect(controller.results, isEmpty);
      expect(controller.isEmpty, isTrue);
      // Not the "nobody on file" state: somebody is, the search just excluded them.
      expect(controller.isEmptyDirectory, isFalse);
      expect(controller.isUnknownNumber, isTrue);
    });

    test('clearing the search brings the whole list back', () async {
      await sellPizza(customerPhone: '9000000108');
      final CustomerDirectoryController controller = await directory(
        query: '9999999999',
      );
      expect(controller.results, isEmpty);

      await controller.clearSearch();

      expect(controller.hasQuery, isFalse);
      expect(controller.results, hasLength(1));
    });

    test('the most recent visitor is listed first', () async {
      await sellPizza(customerPhone: '9000000109');
      await sellPizza(customerPhone: '9000000110');
      // The first customer comes back, which should move them to the top.
      await sellPizza(customerPhone: '9000000109');

      final List<CustomerSummary> listed = (await directory()).results;

      expect(listed.first.phone, '9000000109');
      expect(listed.first.completedOrderCount, 2);
      expect(listed.last.phone, '9000000110');
    });

    test(
      'a customer with no bills is listed with zeroes, not hidden',
      () async {
        // Created directly, which is the one path that makes a customer without a sale.
        await customers.findOrCreateByPhone('9000000111');

        final CustomerSummary summary = (await directory()).results.single;

        expect(summary.phone, '9000000111');
        expect(summary.completedOrderCount, 0);
        expect(summary.totalSpent, Money.zero);
        expect(summary.lastOrderAt, isNull);
        expect(summary.hasOrders, isFalse);
        expect(summary.averageOrderValue, Money.zero);
      },
    );

    test(
      'a storage failure is reported and the list is not guessed at',
      () async {
        await sellPizza(customerPhone: '9000000112');
        await database.database.execute(
          'ALTER TABLE customers RENAME TO customers_moved',
        );

        final CustomerDirectoryController controller = await directory();

        expect(controller.hasError, isTrue);
        expect(controller.errorMessage, isNotEmpty);
        // Not the stale list beside an error message.
        expect(controller.results, isEmpty);

        await database.database.execute(
          'ALTER TABLE customers_moved RENAME TO customers',
        );
        await controller.refresh();

        expect(controller.hasError, isFalse);
        expect(controller.results, hasLength(1));
      },
    );
  });

  // ---------------------------------------------------------------- the history ---

  group('a customer history', () {
    test('it comes from the stored orders', () async {
      final Order settled = await sellPizza(customerPhone: '9000000201');
      final Customer customer = await customerFor('9000000201');

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );

      final Order listed = controller.orders.single;
      expect(listed.id, settled.id);
      expect(listed.orderNumber, settled.orderNumber);
      expect(listed.totalAmount, Money.parse('320'));
      expect(listed.status, OrderStatus.completed);
      expect(controller.paymentMethodOf(listed), PaymentMethod.cash);
      expect(controller.itemSummaryOf(listed), '1 x Cheese Pizza (Medium)');
    });

    test('several bills appear newest first', () async {
      final Order first = await sellPizza(customerPhone: '9000000202');
      final Order second = await sellPizza(
        customerPhone: '9000000202',
        quantity: 2,
      );
      final Order third = await sellPizza(
        customerPhone: '9000000202',
        orderType: OrderType.delivery,
        paymentMethod: PaymentMethod.upi,
      );

      final CustomerHistoryController controller = await historyFor(
        (await customerFor('9000000202')).id,
      );

      expect(controller.orders.map((Order order) => order.id), <String>[
        third.id,
        second.id,
        first.id,
      ]);
      expect(controller.mostRecentOrder!.id, third.id);
      expect(controller.completedOrderCount, 3);
      expect(controller.totalSpent, Money.parse('1280'));
      expect(controller.paymentMethodOf(third), PaymentMethod.upi);
      expect(controller.paymentMethodOf(first), PaymentMethod.cash);
    });

    test('two customers do not see each other bills', () async {
      final Order mine = await sellPizza(customerPhone: '9000000203');
      final Order theirs = await sellPizza(
        customerPhone: '9000000204',
        quantity: 3,
      );

      final CustomerHistoryController first = await historyFor(
        (await customerFor('9000000203')).id,
      );
      final CustomerHistoryController second = await historyFor(
        (await customerFor('9000000204')).id,
      );

      expect(first.orders.single.id, mine.id);
      expect(first.totalSpent, Money.parse('320'));

      expect(second.orders.single.id, theirs.id);
      expect(second.totalSpent, Money.parse('960'));
    });

    test('a walk-in bill belongs to nobody history', () async {
      await sellPizza(customerPhone: '9000000205');
      final Order walkIn = await sellPizza();

      final CustomerHistoryController controller = await historyFor(
        (await customerFor('9000000205')).id,
      );

      expect(
        controller.orders.map((Order order) => order.id),
        isNot(contains(walkIn.id)),
      );
      expect(controller.orders, hasLength(1));
    });

    test('a cancelled bill stays visible but stops counting', () async {
      final Order kept = await sellPizza(customerPhone: '9000000206');
      final Order cancelled = await sellPizza(
        customerPhone: '9000000206',
        quantity: 4,
      );
      await orders.updateStatus(cancelled.id, OrderStatus.cancelled);

      final CustomerHistoryController controller = await historyFor(
        (await customerFor('9000000206')).id,
      );

      // Both bills are in the history, because both happened.
      expect(controller.orders, hasLength(2));
      // Only the settled one is counted, and only its total is spend.
      expect(controller.completedOrderCount, 1);
      expect(controller.totalSpent, Money.parse('320'));
      expect(
        controller.orders
            .firstWhere((Order order) => order.id == kept.id)
            .status,
        OrderStatus.completed,
      );
    });

    test('a customer with a record but no bills says so', () async {
      final Customer customer = (await customers.findOrCreateByPhone(
        '9000000207',
      )).valueOrNull!;

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );

      expect(controller.hasError, isFalse);
      expect(controller.isMissing, isFalse);
      expect(controller.isEmpty, isTrue);
      expect(controller.completedOrderCount, 0);
      expect(controller.totalSpent, Money.zero);
      expect(controller.mostRecentOrder, isNull);
    });

    test(
      'a customer who is no longer on file is reported as missing',
      () async {
        final Customer customer = (await customers.findOrCreateByPhone(
          '9000000208',
        )).valueOrNull!;
        await customers.delete(customer.id);

        final CustomerHistoryController controller = await historyFor(
          customer.id,
        );

        expect(controller.isMissing, isTrue);
        expect(controller.hasError, isFalse);
        expect(controller.orders, isEmpty);
      },
    );

    test('a storage failure is reported without a partial history', () async {
      await sellPizza(customerPhone: '9000000209');
      final Customer customer = await customerFor('9000000209');
      await database.database.execute(
        'ALTER TABLE orders RENAME TO orders_moved',
      );

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );

      expect(controller.hasError, isTrue);
      expect(controller.errorMessage, isNotEmpty);
      // No totals beside the message. A figure nobody should quote is not shown.
      expect(controller.orders, isEmpty);
      expect(controller.summary, isNull);
      expect(controller.totalSpent, Money.zero);

      await database.database.execute(
        'ALTER TABLE orders_moved RENAME TO orders',
      );
      await controller.retry();

      expect(controller.hasError, isFalse);
      expect(controller.orders, hasLength(1));
    });
  });

  // ------------------------------------------------------------- immutability ---

  group('history is immutable', () {
    test('repricing the menu does not change a stored bill', () async {
      final Order settled = await sellPizza(customerPhone: '9000000301');
      final Customer customer = await customerFor('9000000301');
      final MenuItem pizza = await cheesePizza();

      // The owner puts the price up sharply, on the product and on every size.
      await database.database.update(
        'menu_items',
        <String, Object?>{'basePricePaise': 99900},
        where: 'id = ?',
        whereArgs: <Object?>[pizza.id],
      );
      await database.database.update(
        'menu_item_variants',
        <String, Object?>{'pricePaise': 99900},
        where: 'menuItemId = ?',
        whereArgs: <Object?>[pizza.id],
      );
      await database.database.update(
        'menu_item_options',
        <String, Object?>{'pricePaise': 50000},
        where: 'name = ?',
        whereArgs: <Object?>['Extra Cheese'],
      );

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );

      expect(controller.totalSpent, Money.parse('320'));
      expect(controller.orders.single.totalAmount, Money.parse('320'));

      final BillDetailController bill = await billDetail(settled.id);
      final BillLineSnapshot line = bill.lines.single;
      expect(line.unitPrice, Money.parse('320'));
      expect(line.lineTotal, Money.parse('320'));
      expect(line.options.single.price, Money.parse('70'));
      expect(bill.order!.totalAmount, Money.parse('320'));
    });

    test('renaming a menu item does not change a stored bill', () async {
      final Order settled = await sellPizza(customerPhone: '9000000302');
      final Customer customer = await customerFor('9000000302');
      final MenuItem pizza = await cheesePizza();

      await database.database.update(
        'menu_items',
        <String, Object?>{'name': 'Renamed Pizza'},
        where: 'id = ?',
        whereArgs: <Object?>[pizza.id],
      );
      await database.database.update(
        'menu_item_variants',
        <String, Object?>{'name': 'Renamed Size'},
        where: 'menuItemId = ?',
        whereArgs: <Object?>[pizza.id],
      );

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );
      expect(
        controller.itemSummaryOf(controller.orders.single),
        '1 x Cheese Pizza (Medium)',
      );

      final BillDetailController bill = await billDetail(settled.id);
      expect(bill.lines.single.displayName, 'Cheese Pizza (Medium)');
      expect(
        bill.lines.single.options.single.optionNameSnapshot,
        'Extra Cheese',
      );
    });

    test('deleting a menu item does not change a stored bill', () async {
      final Order settled = await sellPizza(customerPhone: '9000000303');
      final Customer customer = await customerFor('9000000303');
      final MenuItem pizza = await cheesePizza();

      // A soft delete, which is how the menu removes a discontinued product.
      await database.database.update(
        'menu_items',
        <String, Object?>{'isDeleted': 1},
        where: 'id = ?',
        whereArgs: <Object?>[pizza.id],
      );
      await database.database.update(
        'menu_item_variants',
        <String, Object?>{'isDeleted': 1},
        where: 'menuItemId = ?',
        whereArgs: <Object?>[pizza.id],
      );

      // Gone from the menu.
      expect(
        (await menu.loadItems()).valueOrNull!.where(
          (MenuItem item) => item.id == pizza.id,
        ),
        isEmpty,
      );

      // Still exactly as sold on the bill.
      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );
      expect(controller.orders, hasLength(1));
      expect(controller.totalSpent, Money.parse('320'));

      final BillDetailController bill = await billDetail(settled.id);
      expect(bill.lines.single.displayName, 'Cheese Pizza (Medium)');
      expect(bill.lines.single.lineTotal, Money.parse('320'));
      expect(bill.order!.totalAmount, Money.parse('320'));
    });

    test('the whole menu can be emptied and the bill still opens', () async {
      final Order settled = await sellPizza(customerPhone: '9000000304');
      final Customer customer = await customerFor('9000000304');

      // Hard-deleted, not soft. The bill's back-references become dangling, which is
      // exactly what the nullable menuItemId on an order line is for.
      await database.database.delete('menu_item_options');
      await database.database.delete('menu_item_variants');
      await database.database.delete('menu_items');
      await database.database.delete('categories');

      final BillDetailController bill = await billDetail(settled.id);
      expect(bill.hasError, isFalse);
      expect(bill.lines.single.displayName, 'Cheese Pizza (Medium)');
      expect(bill.lines.single.unitPrice, Money.parse('320'));
      expect(bill.order!.totalAmount, Money.parse('320'));

      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );
      expect(controller.totalSpent, Money.parse('320'));
    });
  });

  // -------------------------------------------------------------- bill detail ---

  group('a bill detail', () {
    test('it shows the persisted document', () async {
      final Order settled = await sellPizza(
        customerPhone: '9000000401',
        quantity: 2,
        orderType: OrderType.delivery,
        paymentMethod: PaymentMethod.upi,
      );

      final BillDetailController bill = await billDetail(settled.id);

      expect(bill.orderNumber, settled.orderNumber);
      expect(bill.order!.orderType, OrderType.delivery);
      expect(bill.customerPhone, '9000000401');
      expect(bill.paymentMethod, PaymentMethod.upi);
      expect(bill.itemCount, 2);

      final BillLineSnapshot line = bill.lines.single;
      expect(line.displayName, 'Cheese Pizza (Medium)');
      expect(line.quantity, 2);
      expect(line.unitPrice, Money.parse('320'));
      expect(line.lineTotal, Money.parse('640'));
      expect(line.hasOptions, isTrue);
      expect(line.options.single.optionNameSnapshot, 'Extra Cheese');
      expect(line.options.single.quantity, 2);
      expect(line.optionsTotal, Money.parse('140'));

      expect(bill.order!.subtotal, Money.parse('640'));
      expect(bill.order!.discountAmount, Money.zero);
      expect(bill.order!.taxAmount, Money.zero);
      expect(bill.order!.totalAmount, Money.parse('640'));
      expect(bill.linesTotal, Money.parse('640'));
      expect(bill.isConsistent, isTrue);
    });

    test('a walk-in bill carries no phone number', () async {
      final Order settled = await sellPizza();

      final BillDetailController bill = await billDetail(settled.id);

      expect(bill.customerPhone, isNull);
      expect(bill.customer, isNull);
    });

    test(
      'a bill that is not on this terminal is reported as missing',
      () async {
        final BillDetailController bill = await billDetail('ord-not-here');

        expect(bill.isMissing, isTrue);
        expect(bill.hasError, isFalse);
        expect(bill.lines, isEmpty);
      },
    );

    test('a storage failure is reported without half a bill', () async {
      final Order settled = await sellPizza(customerPhone: '9000000402');
      await database.database.execute(
        'ALTER TABLE order_items RENAME TO order_items_moved',
      );

      final BillDetailController bill = await billDetail(settled.id);

      expect(bill.hasError, isTrue);
      // No subtotal beside lines that failed to load.
      expect(bill.order, isNull);
      expect(bill.lines, isEmpty);

      await database.database.execute(
        'ALTER TABLE order_items_moved RENAME TO order_items',
      );
      await bill.retry();

      expect(bill.hasError, isFalse);
      expect(bill.lines, hasLength(1));
    });
  });

  // ----------------------------------------------------------- query surface ---

  group('the order queries the history needs', () {
    test('loadBillLines pairs each line with its own options', () async {
      final Order settled = await sellPizza(customerPhone: '9000000501');
      // A second, plainer line on the same bill.
      final Result<List<BillLineSnapshot>> lines = await orders.loadBillLines(
        settled.id,
      );

      expect(lines.isOk, isTrue);
      final BillLineSnapshot line = lines.valueOrNull!.single;
      expect(line.item.orderId, settled.id);
      expect(line.options.single.orderItemId, line.item.id);
    });

    test(
      'loadBillLines on an unknown order returns nothing, not a failure',
      () async {
        final Result<List<BillLineSnapshot>> lines = await orders.loadBillLines(
          'ord-not-here',
        );

        expect(lines.isOk, isTrue);
        expect(lines.valueOrNull, isEmpty);
      },
    );

    test(
      'loadItemsForOrders groups by bill and skips the empty ones',
      () async {
        final Order first = await sellPizza(customerPhone: '9000000502');
        final Order second = await sellPizza(
          customerPhone: '9000000502',
          quantity: 2,
        );

        final Map<String, List<OrderItem>> grouped =
            (await orders.loadItemsForOrders(<String>[
              first.id,
              second.id,
              'ord-not-here',
            ])).valueOrNull!;

        expect(grouped.keys, unorderedEquals(<String>[first.id, second.id]));
        expect(grouped[first.id]!.single.quantity, 1);
        expect(grouped[second.id]!.single.quantity, 2);
        expect(grouped.containsKey('ord-not-here'), isFalse);
      },
    );

    test(
      'loadItemsForOrders on an empty list asks the database nothing',
      () async {
        final Result<Map<String, List<OrderItem>>> grouped = await orders
            .loadItemsForOrders(const <String>[]);

        expect(grouped.isOk, isTrue);
        expect(grouped.valueOrNull, isEmpty);
      },
    );

    test('loadSettledMethodsForOrders reports one method per bill', () async {
      final Order cash = await sellPizza(customerPhone: '9000000503');
      final Order upi = await sellPizza(
        customerPhone: '9000000503',
        paymentMethod: PaymentMethod.upi,
      );

      final Map<String, PaymentMethod> methods =
          (await payments.loadSettledMethodsForOrders(<String>[
            cash.id,
            upi.id,
          ])).valueOrNull!;

      expect(methods[cash.id], PaymentMethod.cash);
      expect(methods[upi.id], PaymentMethod.upi);
    });

    test('loadOrdersForCustomer returns only that customer bills', () async {
      final Order mine = await sellPizza(customerPhone: '9000000504');
      await sellPizza(customerPhone: '9000000505');
      await sellPizza();

      final Customer customer = await customerFor('9000000504');
      final List<Order> history = (await orders.loadOrdersForCustomer(
        customer.id,
      )).valueOrNull!;

      expect(history.single.id, mine.id);
    });
  });

  // ------------------------------------------------------------------ offline ---

  group('offline', () {
    test('a customer is created and found with no network available', () async {
      // There is no network client in this test at all: the repositories are built over
      // a local in-memory database and nothing else. Both operations are expected to
      // succeed on that alone.
      final Result<Customer> created = await customers.findOrCreateByPhone(
        '9000000601',
      );
      expect(created.isOk, isTrue);

      final Result<Customer?> found = await customers.findByPhone('9000000601');
      expect(found.isOk, isTrue);
      expect(found.valueOrNull!.id, created.valueOrNull!.id);
    });

    test('a bill, its customer and its history all work locally', () async {
      final Order settled = await sellPizza(customerPhone: '9000000602');

      final Customer customer = await customerFor('9000000602');
      final CustomerHistoryController controller = await historyFor(
        customer.id,
      );

      expect(controller.orders.single.id, settled.id);
      expect(controller.completedOrderCount, 1);
      expect(controller.totalSpent, Money.parse('320'));
    });

    test('history survives closing and reopening the database', () async {
      await database.close();
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'brisko_customer_history_test',
      );
      final String dbPath = p.join(tempDir.path, 'customer_history.db');
      addTearDown(() async {
        if (database.isOpen) {
          await database.close();
        }
        if (tempDir.existsSync()) {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      });

      database = await TestDatabase.openOnDisk(dbPath);

      menu = SqliteMenuRepository(database: database);
      checkout = SqliteCheckoutRepository(database: database);
      customers = SqliteCustomerRepository(database: database);
      orders = SqliteOrderRepository(database: database);
      payments = SqlitePaymentRepository(database: database);

      final Order settled = await sellPizza(customerPhone: '9000000603');
      final String customerId = (await customerFor('9000000603')).id;
      await database.close();

      database = await TestDatabase.openOnDisk(dbPath);
      customers = SqliteCustomerRepository(database: database);
      orders = SqliteOrderRepository(database: database);
      payments = SqlitePaymentRepository(database: database);

      final CustomerHistoryController controller = await historyFor(customerId);

      expect(controller.phone, '9000000603');
      expect(controller.orders.single.id, settled.id);
      expect(controller.totalSpent, Money.parse('320'));
    });
  });
}
