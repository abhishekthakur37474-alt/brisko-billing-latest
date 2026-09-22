import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';

/// The Order + KOT workflow, end to end, against the real database and seeded menu.
///
/// Every bill here is rung up through the billing controller over the real menu
/// repository, so the names and prices that end up on a kitchen slip travelled the
/// production path from the seed. The transaction under test is the one the
/// application runs.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteKotRepository kots;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    kots = SqliteKotRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// A Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  Future<Cart> pizzaCart({int quantity = 1}) =>
      SeededCart.mediumCheesePizzaWithExtraCheese(menu, quantity: quantity);

  BillSettlement settlementFor(
    Cart cart, {
    OrderType orderType = OrderType.takeaway,
    String? notes,
  }) => BillSettlement.fromCart(
    cart: cart,
    orderType: orderType,
    paymentMethod: PaymentMethod.cash,
    notes: notes,
  );

  /// Rows physically present, ignoring the soft-delete filter repositories apply.
  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Settles a bill and returns the order, failing the test if it did not settle.
  Future<Order> settle(BillSettlement settlement) async {
    final Result<Order> result = await checkout.settle(settlement);
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.valueOrNull!;
  }

  /// The single slip raised for [order], read back through the repository.
  Future<KitchenTicket> ticketFor(Order order) async {
    final List<KitchenTicket> board =
        (await kots.loadActiveTickets()).valueOrNull!;
    return board.singleWhere(
      (KitchenTicket ticket) => ticket.record.orderId == order.id,
    );
  }

  group('a settled bill raises exactly one kitchen slip', () {
    test('one order, one payment, one slip', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);

      // And the slip belongs to that order rather than merely existing.
      expect((await kots.loadForOrder(order.id)).valueOrNull, hasLength(1));
    });

    test('the slip carries the number the customer was given', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      final KitchenTicket ticket = await ticketFor(order);

      expect(order.orderNumber, matches(RegExp(r'^\d{8}-0001$')));
      expect(ticket.orderNumber, order.orderNumber);
      // Its own number too, so the counter and kitchen can refer to the slip.
      expect(ticket.kotNumber, matches(RegExp(r'^K\d{8}-0001$')));
    });

    test('the slip carries the order type, for every type', () async {
      for (final OrderType type in OrderType.values) {
        final Order order = await settle(
          settlementFor(await pizzaCart(), orderType: type),
        );

        expect(
          (await ticketFor(order)).orderType,
          type,
          reason: 'slip for a ${type.label} order',
        );
      }
    });

    test('a new slip is pending, and the bill is settled', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      // Payment and preparation are separate facts. The bill is closed; the food
      // has not been started.
      expect(order.status, OrderStatus.completed);
      expect((await ticketFor(order)).status, KotStatus.pending);
    });

    test('an order note reaches the kitchen', () async {
      final Order order = await settle(
        settlementFor(await pizzaCart(), notes: 'Cut into eight'),
      );

      final KitchenTicket ticket = await ticketFor(order);
      expect(ticket.hasNotes, isTrue);
      expect(ticket.notes, 'Cut into eight');
    });

    test('slip numbers run in sequence for the day', () async {
      await settle(settlementFor(await pizzaCart()));
      await settle(settlementFor(await pizzaCart()));

      final List<KitchenTicket> board =
          (await kots.loadActiveTickets()).valueOrNull!;

      expect(board.map((KitchenTicket ticket) => ticket.kotNumber), <Matcher>[
        endsWith('-0001'),
        endsWith('-0002'),
      ]);
    });
  });

  group('the slip is a snapshot of the order', () {
    test('the lines say what was sold, with size and options', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      final KitchenTicket ticket = await ticketFor(order);
      expect(ticket.lines, hasLength(1));

      final KitchenTicketLine line = ticket.lines.single;
      expect(line.item.itemNameSnapshot, 'Cheese Pizza');
      expect(line.item.variantNameSnapshot, 'Medium');
      expect(line.displayName, 'Cheese Pizza (Medium)');
      expect(line.options, hasLength(1));
      expect(line.options.single.optionNameSnapshot, 'Extra Cheese');
      expect(line.optionSummary, 'Extra Cheese');

      // No price anywhere on the slip: the kitchen is told what to cook.
      final List<Map<String, Object?>> columns = await database.database
          .rawQuery('PRAGMA table_info(kot_item_options)');
      final Set<String> names = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toSet();
      expect(names, isNot(contains('pricePaise')));
    });

    test('the quantity is the quantity that was ordered', () async {
      final Order order = await settle(
        settlementFor(await pizzaCart(quantity: 2)),
      );

      final KitchenTicketLine line = (await ticketFor(order)).lines.single;
      expect(line.quantity, 2);
      // Two pizzas, so two portions of extra cheese.
      expect(line.options.single.quantity, 2);
      expect((await ticketFor(order)).totalQuantity, 2);
    });

    test('lines stay in the order the cashier entered them', () async {
      final controller = await SeededCart.controller(menu);
      addTearDown(controller.dispose);

      await SeededCart.add(
        controller,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
        options: <String>['Extra Cheese'],
      );
      await SeededCart.add(
        controller,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Large',
      );
      await SeededCart.add(
        controller,
        category: 'SIDE ORDER',
        item: 'French Fries',
        options: <String>['Ketchup'],
      );

      final Order order = await settle(settlementFor(controller.cart));

      expect(
        (await ticketFor(order)).lines
            .map((KitchenTicketLine line) => line.displayName),
        <String>[
          'Cheese Pizza (Medium)',
          'Cheese Pizza (Large)',
          'French Fries',
        ],
      );
      // And each line kept its own options.
      expect(
        (await ticketFor(order)).lines
            .map((KitchenTicketLine line) => line.optionSummary),
        <String>['Extra Cheese', '', 'Ketchup'],
      );
    });

    test('repricing the menu afterwards leaves the slip alone', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket before = await ticketFor(order);

      // The owner puts the Medium up to ₹300 the following week.
      final MenuItemVariant medium = await _mediumCheesePizza(menu);
      expect(medium.price, Money.parse('250'));
      expect(
        (await menu.saveVariant(
          medium.copyWith(price: Money.parse('300'), updatedAt: DateTime.now()),
        )).isOk,
        isTrue,
      );
      expect((await _mediumCheesePizza(menu)).price, Money.parse('300'));

      final KitchenTicket after = await ticketFor(order);
      expect(after.lines.single.displayName, before.lines.single.displayName);
      expect(after.lines.single.item.variantNameSnapshot, 'Medium');
      expect(after.lines.single.optionSummary, 'Extra Cheese');
      expect(after.lines.single.quantity, before.lines.single.quantity);
    });

    test('renaming the menu afterwards leaves the slip alone', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      final MenuItem pizza = await _cheesePizza(menu);
      expect(
        (await menu.saveItem(
          pizza.copyWith(
            name: 'Classic Cheese Pizza',
            updatedAt: DateTime.now(),
          ),
        )).isOk,
        isTrue,
      );
      expect(
        (await _cheesePizza(menu, name: 'Classic Cheese Pizza')).id,
        pizza.id,
      );

      final KitchenTicketLine line = (await ticketFor(order)).lines.single;
      expect(line.item.itemNameSnapshot, 'Cheese Pizza');
      expect(line.displayName, 'Cheese Pizza (Medium)');
    });

    test('renaming a size afterwards leaves the slip alone', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));

      final MenuItemVariant medium = await _mediumCheesePizza(menu);
      expect(
        (await menu.saveVariant(
          medium.copyWith(name: 'Regular', updatedAt: DateTime.now()),
        )).isOk,
        isTrue,
      );

      expect(
        (await ticketFor(order)).lines.single.displayName,
        'Cheese Pizza (Medium)',
      );
    });
  });

  group('the slip and the bill commit together', () {
    test('a slip that cannot be written rolls the whole sale back', () async {
      // A storage fault reached only when the slip lines are inserted: the order,
      // its lines, its options, the payment and the slip header have all been
      // written by then. This is the case that would otherwise leave a customer
      // holding a paid bill the kitchen never heard about.
      await database.database.execute('DROP TABLE kot_items');

      final Result<Order> result = await checkout.settle(
        settlementFor(await pizzaCart()),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<LocalStorageFailure>());

      // Nothing at all.
      expect(await rowCount('orders'), 0);
      expect(await rowCount('order_items'), 0);
      expect(await rowCount('order_item_options'), 0);
      expect(await rowCount('payments'), 0);
      expect(await rowCount('kot_records'), 0);
    });

    test('a failed sale consumes no slip number', () async {
      await database.database.execute('DROP TABLE kot_items');
      expect(
        (await checkout.settle(settlementFor(await pizzaCart()))).isErr,
        isTrue,
      );
      await database.close();

      // The terminal is restarted onto a working database and the bill re-rung.
      database = await TestDatabase.openInMemory();
      menu = SqliteMenuRepository(database: database);
      checkout = SqliteCheckoutRepository(database: database);
      kots = SqliteKotRepository(database: database);

      final Order order = await settle(settlementFor(await pizzaCart()));
      expect((await ticketFor(order)).kotNumber, endsWith('-0001'));
    });

    test('a duplicate submission cannot raise a second slip', () async {
      final BillSettlement settlement = settlementFor(await pizzaCart());

      final Result<Order> first = await checkout.settle(settlement);
      final Result<Order> second = await checkout.settle(settlement);

      expect(first.isOk, isTrue);
      expect(second.isErr, isTrue);
      expect(second.failureOrNull!.message, contains('already been settled'));

      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);
      expect(await rowCount('kot_items'), 1);
      expect(await rowCount('kot_item_options'), 1);
    });

    test('two submissions racing raise one slip between them', () async {
      final BillSettlement settlement = settlementFor(await pizzaCart());

      final List<Result<Order>> results = await Future.wait<Result<Order>>(
        <Future<Result<Order>>>[
          checkout.settle(settlement),
          checkout.settle(settlement),
        ],
      );

      expect(results.where((Result<Order> r) => r.isOk), hasLength(1));
      expect(await rowCount('orders'), 1);
      expect(await rowCount('kot_records'), 1);
    });

    test('the slip id is fixed when the bill is built', () async {
      // What makes a retry safe: the same bill can only ever write the same slip.
      final BillSettlement settlement = settlementFor(await pizzaCart());
      final Order order = await settle(settlement);

      expect((await ticketFor(order)).id, settlement.kotId);
    });
  });

  group('the preparation workflow', () {
    test('pending moves to preparing', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      expect(
        (await kots.advanceStatus(ticket.id, KotStatus.preparing)).isOk,
        isTrue,
      );

      expect(
        (await kots.findKot(ticket.id)).valueOrNull!.status,
        KotStatus.preparing,
      );
      expect((await ticketFor(order)).status, KotStatus.preparing);
    });

    test('preparing moves to ready', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      await kots.advanceStatus(ticket.id, KotStatus.preparing);
      expect(
        (await kots.advanceStatus(ticket.id, KotStatus.ready)).isOk,
        isTrue,
      );

      expect(
        (await kots.findKot(ticket.id)).valueOrNull!.status,
        KotStatus.ready,
      );
    });

    test('advancing does not touch the bill', () async {
      // The money was collected at the counter. Cooking the food does not change
      // that, and the order must not be reopened by it.
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      await kots.advanceStatus(ticket.id, KotStatus.preparing);
      await kots.advanceStatus(ticket.id, KotStatus.ready);

      final List<Map<String, Object?>> rows = await database.database.query(
        'orders',
        columns: <String>['status'],
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      );
      expect(rows.single['status'], OrderStatus.completed.name);
    });

    test('a skipped state is refused', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      final Result<void> result = await kots.advanceStatus(
        ticket.id,
        KotStatus.ready,
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
      expect((await ticketFor(order)).status, KotStatus.pending);
    });

    test('a move backwards is refused', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);
      await kots.advanceStatus(ticket.id, KotStatus.preparing);
      await kots.advanceStatus(ticket.id, KotStatus.ready);

      for (final KotStatus backwards in <KotStatus>[
        KotStatus.preparing,
        KotStatus.pending,
      ]) {
        final Result<void> result = await kots.advanceStatus(
          ticket.id,
          backwards,
        );
        expect(result.isErr, isTrue, reason: 'ready to ${backwards.name}');
        expect(result.failureOrNull, isA<ValidationFailure>());
      }

      expect((await ticketFor(order)).status, KotStatus.ready);
    });

    test('re-advancing to the state it is already in is refused', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      expect(
        (await kots.advanceStatus(ticket.id, KotStatus.pending)).isErr,
        isTrue,
      );

      // And a repeated press of the same button lands once.
      await kots.advanceStatus(ticket.id, KotStatus.preparing);
      expect(
        (await kots.advanceStatus(ticket.id, KotStatus.preparing)).isErr,
        isTrue,
      );
      expect((await ticketFor(order)).status, KotStatus.preparing);
    });

    test('advancing a slip that does not exist is refused', () async {
      final Result<void> result = await kots.advanceStatus(
        'kot-does-not-exist',
        KotStatus.preparing,
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('a finished slip leaves the board', () async {
      final Order order = await settle(settlementFor(await pizzaCart()));
      final KitchenTicket ticket = await ticketFor(order);

      // Set by an order-level action rather than by the kitchen board.
      expect(
        (await kots.updateStatus(ticket.id, KotStatus.completed)).isOk,
        isTrue,
      );

      expect((await kots.loadActiveTickets()).valueOrNull, isEmpty);
    });

    test('the board is empty when nothing has been sold', () async {
      expect((await kots.loadActiveTickets()).valueOrNull, isEmpty);
    });

    test('the board holds every outstanding state at once', () async {
      final Order first = await settle(settlementFor(await pizzaCart()));
      final Order second = await settle(settlementFor(await pizzaCart()));
      await settle(settlementFor(await pizzaCart()));

      await kots.advanceStatus(
        (await ticketFor(first)).id,
        KotStatus.preparing,
      );
      await kots.advanceStatus(
        (await ticketFor(second)).id,
        KotStatus.preparing,
      );
      await kots.advanceStatus((await ticketFor(second)).id, KotStatus.ready);

      final List<KitchenTicket> board =
          (await kots.loadActiveTickets()).valueOrNull!;
      expect(board, hasLength(3));
      expect(
        board.map((KitchenTicket ticket) => ticket.status).toSet(),
        <KotStatus>{KotStatus.pending, KotStatus.preparing, KotStatus.ready},
      );
      // Oldest first, so the kitchen works down the list.
      expect(board.map((KitchenTicket ticket) => ticket.kotNumber), <Matcher>[
        endsWith('-0001'),
        endsWith('-0002'),
        endsWith('-0003'),
      ]);
    });
  });

  group('KotStatus', () {
    test('the workflow is pending, preparing, ready, and stops', () {
      expect(KotStatus.pending.nextStep, KotStatus.preparing);
      expect(KotStatus.preparing.nextStep, KotStatus.ready);
      expect(KotStatus.ready.nextStep, isNull);
    });

    test('only the forward move is allowed', () {
      expect(KotStatus.pending.canAdvanceTo(KotStatus.preparing), isTrue);
      expect(KotStatus.preparing.canAdvanceTo(KotStatus.ready), isTrue);

      // Skipping, repeating and reversing are all refused.
      expect(KotStatus.pending.canAdvanceTo(KotStatus.ready), isFalse);
      expect(KotStatus.pending.canAdvanceTo(KotStatus.pending), isFalse);
      expect(KotStatus.preparing.canAdvanceTo(KotStatus.pending), isFalse);
      expect(KotStatus.ready.canAdvanceTo(KotStatus.preparing), isFalse);
      expect(KotStatus.ready.canAdvanceTo(KotStatus.completed), isFalse);
    });

    test('the board shows exactly the outstanding states', () {
      expect(
        KotStatus.values.where((KotStatus status) => status.isActive),
        <KotStatus>[KotStatus.pending, KotStatus.preparing, KotStatus.ready],
      );
    });

    test('every state reads plainly, and only two offer a move', () {
      expect(KotStatus.preparing.label, 'Preparing');
      expect(KotStatus.ready.label, 'Ready');
      expect(KotStatus.pending.advanceLabel, 'Start preparing');
      expect(KotStatus.preparing.advanceLabel, 'Mark ready');
      expect(KotStatus.ready.advanceLabel, isNull);
      expect(KotStatus.completed.advanceLabel, isNull);
    });
  });
}

/// The seeded Cheese Pizza, read through the menu repository.
Future<MenuItem> _cheesePizza(
  SqliteMenuRepository menu, {
  String name = 'Cheese Pizza',
}) async {
  final List<MenuItem> items = (await menu.loadItems()).valueOrNull!;
  return items.firstWhere((MenuItem item) => item.name == name);
}

/// The seeded Medium size of the Cheese Pizza.
Future<MenuItemVariant> _mediumCheesePizza(SqliteMenuRepository menu) async {
  final MenuItem pizza = await _cheesePizza(menu);
  final List<MenuItemVariant> sizes = (await menu.loadVariants(pizza.id))
      .valueOrNull!;
  return sizes.firstWhere((MenuItemVariant size) => size.name == 'Medium');
}
