import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_held_bill_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line_option.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_draft.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_status.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_summary.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/flaky_database.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';

/// Held bills against the real database and the real seeded menu.
///
/// The carts are assembled through `BillingController` over [SqliteMenuRepository], so
/// every price that ends up in an assertion travelled the production path from the seed.
/// Nothing is stubbed, and the transactions under test are the ones the application runs.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteHeldBillRepository held;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    held = SqliteHeldBillRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  /// A Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  Future<Cart> pizzaCart({int quantity = 1}) =>
      SeededCart.mediumCheesePizzaWithExtraCheese(menu, quantity: quantity);

  Future<int> rowsIn(String table) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      table,
    );
    return rows.length;
  }

  /// Holds [cart] and fails the test loudly if it could not be held.
  Future<HeldBill> hold(
    Cart cart, {
    OrderType orderType = OrderType.takeaway,
    String? customerPhone,
    String? notes,
  }) async {
    final Result<HeldBill> result = await held.hold(
      HeldBillDraft.fromCart(
        cart: cart,
        orderType: orderType,
        customerPhone: customerPhone,
        notes: notes,
      ),
    );
    expect(
      result.isOk,
      isTrue,
      reason: 'arrangement failed: ${result.failureOrNull?.message}',
    );
    return result.valueOrNull!;
  }

  group('holding a bill', () {
    test('an empty cart is refused', () async {
      final Result<HeldBill> result = await held.hold(
        HeldBillDraft.fromCart(
          cart: const Cart.empty(),
          orderType: OrderType.takeaway,
        ),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('nothing on this bill'));
    });

    test('an empty cart writes no rows at all', () async {
      await held.hold(
        HeldBillDraft.fromCart(
          cart: const Cart.empty(),
          orderType: OrderType.takeaway,
        ),
      );

      expect(await rowsIn(SqliteTables.heldBills), 0);
      expect(await rowsIn(SqliteTables.heldBillLines), 0);
      expect(await rowsIn(SqliteTables.heldBillLineOptions), 0);
    });

    test('a populated cart is held', () async {
      final HeldBill record = await hold(await pizzaCart());

      expect(record.status, HeldBillStatus.held);
      expect(record.isAvailable, isTrue);
      expect(record.lineCount, 1);
      expect(record.itemCount, 1);
      expect(record.subtotal.paise, 32000);
    });

    test('the header, its line and its option are all written', () async {
      await hold(await pizzaCart());

      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect(await rowsIn(SqliteTables.heldBillLines), 1);
      expect(await rowsIn(SqliteTables.heldBillLineOptions), 1);
    });

    test('the order type, phone and note are kept', () async {
      final HeldBill record = await hold(
        await pizzaCart(),
        orderType: OrderType.delivery,
        customerPhone: '+91 90000 00001',
        notes: '  no onions  ',
      );

      expect(record.orderType, OrderType.delivery);
      // Normalised to the ten digits that are the customer lookup key.
      expect(record.customerPhone, '9000000001');
      expect(record.notes, 'no onions');
    });

    test('a walk-in bill holds no phone number', () async {
      final HeldBill record = await hold(await pizzaCart());

      expect(record.customerPhone, isNull);
      expect(record.hasCustomerPhone, isFalse);
    });

    test('a half-typed number is dropped rather than stored short', () async {
      // Truncation would file the bill against a different customer. See CustomerPhone.
      final HeldBill record = await hold(
        await pizzaCart(),
        customerPhone: '98765',
      );

      expect(record.customerPhone, isNull);
    });

    test('holding the same draft twice is refused the second time', () async {
      final HeldBillDraft draft = HeldBillDraft.fromCart(
        cart: await pizzaCart(),
        orderType: OrderType.takeaway,
      );

      expect((await held.hold(draft)).isOk, isTrue);
      final Result<HeldBill> again = await held.hold(draft);

      expect(again.isErr, isTrue);
      expect(again.failureOrNull, isA<ValidationFailure>());
      expect(again.failureOrNull!.message, contains('already been held'));
    });

    test('a refused second hold does not duplicate the lines', () async {
      final HeldBillDraft draft = HeldBillDraft.fromCart(
        cart: await pizzaCart(),
        orderType: OrderType.takeaway,
      );

      await held.hold(draft);
      await held.hold(draft);

      // The upsert would have rewritten the header and appended a second copy of every
      // line, leaving the pizza on the bill twice.
      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect(await rowsIn(SqliteTables.heldBillLines), 1);
      expect(await rowsIn(SqliteTables.heldBillLineOptions), 1);
    });
  });

  group('the held snapshot', () {
    test('every line snapshot is stored', () async {
      final Cart cart = await pizzaCart(quantity: 3);
      final CartLine original = cart.lines.single;
      final HeldBill record = await hold(cart);

      final CartLine stored = (await held.findHeldBill(record.id))
          .valueOrNull!
          .cart
          .lines
          .single;

      expect(stored.id, original.id);
      expect(stored.menuItemId, original.menuItemId);
      expect(stored.variantId, original.variantId);
      expect(stored.itemNameSnapshot, 'Cheese Pizza');
      expect(stored.variantNameSnapshot, 'Medium');
      expect(stored.basePriceSnapshot.paise, 25000);
      expect(stored.quantity, 3);
    });

    test('every option snapshot is stored', () async {
      final HeldBill record = await hold(await pizzaCart());

      final CartLineOption stored = (await held.findHeldBill(record.id))
          .valueOrNull!
          .cart
          .lines
          .single
          .options
          .single;

      expect(stored.nameSnapshot, 'Extra Cheese');
      expect(stored.optionType, MenuOptionType.addOn);
      expect(stored.priceSnapshot.paise, 7000);
      expect(stored.optionId, isNotEmpty);
    });

    test('the lines keep the order they were rung up in', () async {
      final controller = await SeededCart.controller(menu);
      addTearDown(controller.dispose);
      await SeededCart.add(
        controller,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
      );
      await SeededCart.add(
        controller,
        category: 'SIDE ORDER',
        item: 'French Fries',
      );
      await SeededCart.add(
        controller,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Large',
      );

      final List<String> expected = controller.cart.lines
          .map((CartLine line) => line.displayName)
          .toList();
      final HeldBill record = await hold(controller.cart);

      final HeldBill? stored = (await held.findHeldBill(record.id)).valueOrNull;

      expect(
        stored!.cart.lines.map((CartLine line) => line.displayName).toList(),
        expected,
      );
    });

    test(
      'two identically configured lines are not merged on the way back',
      () async {
        // `Cart.addLine` folds a repeat into the existing line, which is right at the
        // counter and wrong when restoring a snapshot: it would hand back a cart that is
        // not the cart that was held.
        final CartLine line = (await pizzaCart()).lines.single;
        final Cart cart = Cart(<CartLine>[
          line,
          CartLine(
            id: 'line-second-copy',
            menuItemId: line.menuItemId,
            variantId: line.variantId,
            itemNameSnapshot: line.itemNameSnapshot,
            variantNameSnapshot: line.variantNameSnapshot,
            basePriceSnapshot: line.basePriceSnapshot,
            quantity: line.quantity,
            options: line.options,
          ),
        ]);

        final HeldBill record = await hold(cart);
        final HeldBill stored = (await held.findHeldBill(record.id))
            .valueOrNull!;

        expect(stored.cart.lineCount, 2);
        expect(stored.subtotal.paise, 64000);
      },
    );
  });

  group('the menu changing underneath', () {
    test('repricing the item does not change the held bill', () async {
      final HeldBill record = await hold(await pizzaCart());

      final MenuItemVariant medium = (await menu.loadVariants(
        record.cart.lines.single.menuItemId,
      )).valueOrNull!.firstWhere((MenuItemVariant v) => v.name == 'Medium');
      // Doubled, which is the kind of change that would be obvious if it leaked through.
      expect(
        (await menu.saveVariant(
          MenuItemVariant(
            id: medium.id,
            menuItemId: medium.menuItemId,
            name: medium.name,
            price: medium.price * 2,
            displayOrder: medium.displayOrder,
            createdAt: medium.createdAt,
            updatedAt: DateTime.now().toUtc(),
          ),
        )).isOk,
        isTrue,
      );

      final HeldBill stored = (await held.findHeldBill(record.id)).valueOrNull!;

      expect(stored.cart.lines.single.basePriceSnapshot.paise, 25000);
      expect(stored.subtotal.paise, 32000);
    });

    test('repricing an option does not change the held bill', () async {
      final HeldBill record = await hold(await pizzaCart());
      final String optionId = record.cart.lines.single.options.single.optionId;

      final List<MenuItemOptionUpdate> updates = <MenuItemOptionUpdate>[];
      for (final option in (await menu.loadAllOptions()).valueOrNull!) {
        if (option.id == optionId) {
          updates.add(MenuItemOptionUpdate(option));
        }
      }
      expect(updates, hasLength(1));
      expect((await menu.saveOption(updates.single.doubled())).isOk, isTrue);

      final HeldBill stored = (await held.findHeldBill(record.id)).valueOrNull!;

      expect(stored.cart.lines.single.options.single.priceSnapshot.paise, 7000);
      expect(stored.subtotal.paise, 32000);
    });

    test('renaming the item does not change the held bill', () async {
      final HeldBill record = await hold(await pizzaCart());
      final String menuItemId = record.cart.lines.single.menuItemId;

      final MenuItem item = (await menu.findItem(menuItemId)).valueOrNull!;
      expect(
        (await menu.saveItem(
          MenuItem(
            id: item.id,
            categoryId: item.categoryId,
            name: 'Renamed Pizza',
            itemType: item.itemType,
            basePrice: item.basePrice,
            isAvailable: item.isAvailable,
            createdAt: item.createdAt,
            updatedAt: DateTime.now().toUtc(),
          ),
        )).isOk,
        isTrue,
      );

      final HeldBill stored = (await held.findHeldBill(record.id)).valueOrNull!;

      expect(stored.cart.lines.single.itemNameSnapshot, 'Cheese Pizza');
      expect(stored.cart.lines.single.displayName, 'Cheese Pizza (Medium)');
    });

    test('withdrawing the item does not break the held bill', () async {
      final HeldBill record = await hold(await pizzaCart());
      final String menuItemId = record.cart.lines.single.menuItemId;

      expect((await menu.deleteItem(menuItemId)).isOk, isTrue);
      // Gone from the menu the counter can sell from.
      expect((await menu.findItem(menuItemId)).valueOrNull, isNull);

      final Result<HeldBill?> reread = await held.findHeldBill(record.id);

      expect(reread.isOk, isTrue);
      expect(
        reread.valueOrNull!.cart.lines.single.itemNameSnapshot,
        'Cheese Pizza',
      );
      expect(reread.valueOrNull!.subtotal.paise, 32000);
    });

    test('a withdrawn item can still be resumed', () async {
      final HeldBill record = await hold(await pizzaCart());
      await menu.deleteItem(record.cart.lines.single.menuItemId);

      final Result<HeldBill> resumed = await held.resume(record.id);

      expect(resumed.isOk, isTrue);
      expect(
        resumed.valueOrNull!.cart.lines.single.itemNameSnapshot,
        'Cheese Pizza',
      );
    });
  });

  group('the list', () {
    test('is empty on a fresh terminal', () async {
      final Result<List<HeldBillSummary>> list = await held.loadHeldBills();

      expect(list.isOk, isTrue);
      expect(list.valueOrNull, isEmpty);
    });

    test('describes a held bill well enough to tell it apart', () async {
      await hold(
        await pizzaCart(quantity: 2),
        orderType: OrderType.dineIn,
        customerPhone: '9000000001',
      );

      final HeldBillSummary summary =
          (await held.loadHeldBills()).valueOrNull!.single;

      expect(summary.orderType, OrderType.dineIn);
      expect(summary.lineCount, 1);
      expect(summary.itemCount, 2);
      expect(summary.subtotal.paise, 64000);
      expect(summary.customerPhoneDisplay, '90000 00001');
      expect(summary.countsLabel, '1 line \u00b7 2 items');
      expect(summary.isAvailable, isTrue);
    });

    test('the stored total matches the total the cart computes', () async {
      final HeldBill record = await hold(await pizzaCart(quantity: 3));

      final HeldBillSummary summary =
          (await held.loadHeldBills()).valueOrNull!.single;
      final HeldBill reread = (await held.findHeldBill(record.id)).valueOrNull!;

      // The denormalised column and the sum over the restored lines are the same figure,
      // because the column was written from the lines.
      expect(summary.subtotal, reread.subtotal);
      expect(summary.subtotal.paise, 96000);
    });

    test('is oldest first', () async {
      final HeldBill first = await hold(await pizzaCart(), notes: 'first');
      final HeldBill second = await hold(await pizzaCart(), notes: 'second');

      final List<HeldBillSummary> list =
          (await held.loadHeldBills()).valueOrNull!;

      expect(list.map((HeldBillSummary s) => s.id).toList(), <String>[
        first.id,
        second.id,
      ]);
    });

    test('a resumed bill leaves the list', () async {
      final HeldBill record = await hold(await pizzaCart());
      expect((await held.loadHeldBills()).valueOrNull, hasLength(1));

      await held.resume(record.id);

      expect((await held.loadHeldBills()).valueOrNull, isEmpty);
    });

    test('a cancelled bill leaves the list', () async {
      final HeldBill record = await hold(await pizzaCart());

      await held.cancel(record.id);

      expect((await held.loadHeldBills()).valueOrNull, isEmpty);
    });
  });

  group('resuming', () {
    test('returns the exact cart that was held', () async {
      final Cart original = await pizzaCart(quantity: 2);
      final HeldBill record = await hold(original);

      final Cart resumed = (await held.resume(record.id)).valueOrNull!.cart;

      expect(resumed.lineCount, original.lineCount);
      expect(resumed.itemCount, original.itemCount);
      expect(resumed.subtotal, original.subtotal);
      expect(resumed.lines.single.id, original.lines.single.id);
      expect(resumed.lines.single.unitPrice, original.lines.single.unitPrice);
      expect(resumed.lines.single.lineTotal, original.lines.single.lineTotal);
    });

    test('preserves the option prices', () async {
      final Cart original = await pizzaCart();
      final HeldBill record = await hold(original);

      final CartLineOption resumed = (await held.resume(record.id))
          .valueOrNull!
          .cart
          .lines
          .single
          .options
          .single;

      expect(resumed, original.lines.single.options.single);
      expect(resumed.priceSnapshot.paise, 7000);
    });

    test('the resumed cart is still editable as a cart', () async {
      final HeldBill record = await hold(await pizzaCart());
      final Cart resumed = (await held.resume(record.id)).valueOrNull!.cart;

      // The line id survived the round trip, so a quantity edit finds the line.
      final Cart edited = resumed.increaseQuantity(resumed.lines.single.id);

      expect(edited.lines.single.quantity, 2);
      expect(edited.subtotal.paise, 64000);
    });

    test('marks the bill resumed', () async {
      final HeldBill record = await hold(await pizzaCart());

      final HeldBill resumed = (await held.resume(record.id)).valueOrNull!;

      expect(resumed.status, HeldBillStatus.resumed);
      expect(resumed.isAvailable, isFalse);
      expect(
        (await held.findHeldBill(record.id)).valueOrNull!.status,
        HeldBillStatus.resumed,
      );
    });

    test('a second resume is refused', () async {
      final HeldBill record = await hold(await pizzaCart());
      await held.resume(record.id);

      final Result<HeldBill> again = await held.resume(record.id);

      expect(again.isErr, isTrue);
      expect(again.failureOrNull, isA<ValidationFailure>());
      expect(again.failureOrNull!.message, contains('already been resumed'));
    });

    test('a bill that is not there is refused', () async {
      final Result<HeldBill> missing = await held.resume('hld-nothing');

      expect(missing.isErr, isTrue);
      expect(missing.failureOrNull, isA<ValidationFailure>());
      expect(
        missing.failureOrNull!.message,
        contains('no longer on this terminal'),
      );
    });

    test('a cancelled bill cannot be resumed', () async {
      final HeldBill record = await hold(await pizzaCart());
      await held.cancel(record.id);

      final Result<HeldBill> resumed = await held.resume(record.id);

      expect(resumed.isErr, isTrue);
      expect(
        resumed.failureOrNull!.message,
        contains('already been cancelled'),
      );
    });

    test('resuming writes nothing outside the held bill tables', () async {
      final HeldBill record = await hold(await pizzaCart());

      await held.resume(record.id);

      // Nothing has been sold, so nothing exists to be sold.
      expect(await rowsIn(SqliteTables.orders), 0);
      expect(await rowsIn(SqliteTables.orderItems), 0);
      expect(await rowsIn(SqliteTables.payments), 0);
      expect(await rowsIn(SqliteTables.kotRecords), 0);
      expect(await rowsIn(SqliteTables.stockMovements), 0);
      expect(await rowsIn(SqliteTables.orderInventoryDeductions), 0);
      expect(await rowsIn(SqliteTables.customers), 0);
    });

    test('resuming a bill with a phone creates no customer', () async {
      final HeldBill record = await hold(
        await pizzaCart(),
        customerPhone: '9000000001',
      );

      final HeldBill resumed = (await held.resume(record.id)).valueOrNull!;

      // The number came back so settlement can use it, and no record was created for it.
      expect(resumed.customerPhone, '9000000001');
      expect(await rowsIn(SqliteTables.customers), 0);
    });

    test('the lines are left in place for audit', () async {
      final HeldBill record = await hold(await pizzaCart());

      await held.resume(record.id);

      expect(await rowsIn(SqliteTables.heldBillLines), 1);
      expect(await rowsIn(SqliteTables.heldBillLineOptions), 1);
      expect(
        (await held.findHeldBill(record.id)).valueOrNull!.cart.lineCount,
        1,
      );
    });
  });

  group('cancelling a held bill', () {
    test('marks it cancelled rather than deleting it', () async {
      final HeldBill record = await hold(await pizzaCart());

      final Result<HeldBill> cancelled = await held.cancel(record.id);

      expect(cancelled.isOk, isTrue);
      expect(cancelled.valueOrNull!.status, HeldBillStatus.cancelled);
      // Still there, and still readable, which is what makes the abandonment auditable.
      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect((await held.findHeldBill(record.id)).valueOrNull, isNotNull);
    });

    test('creates no sale, no payment and no kitchen slip', () async {
      final HeldBill record = await hold(await pizzaCart());

      await held.cancel(record.id);

      expect(await rowsIn(SqliteTables.orders), 0);
      expect(await rowsIn(SqliteTables.orderItems), 0);
      expect(await rowsIn(SqliteTables.orderItemOptions), 0);
      expect(await rowsIn(SqliteTables.payments), 0);
      expect(await rowsIn(SqliteTables.kotRecords), 0);
      expect(await rowsIn(SqliteTables.kotItems), 0);
    });

    test('moves no stock', () async {
      final HeldBill record = await hold(await pizzaCart());

      await held.cancel(record.id);

      expect(await rowsIn(SqliteTables.stockMovements), 0);
      expect(await rowsIn(SqliteTables.orderInventoryDeductions), 0);
    });

    test('creates no customer', () async {
      final HeldBill record = await hold(
        await pizzaCart(),
        customerPhone: '9000000001',
      );

      await held.cancel(record.id);

      expect(await rowsIn(SqliteTables.customers), 0);
    });

    test('a second cancellation is refused', () async {
      final HeldBill record = await hold(await pizzaCart());
      await held.cancel(record.id);

      final Result<HeldBill> again = await held.cancel(record.id);

      expect(again.isErr, isTrue);
      expect(again.failureOrNull!.message, contains('already been cancelled'));
    });

    test('a resumed bill cannot be cancelled', () async {
      final HeldBill record = await hold(await pizzaCart());
      await held.resume(record.id);

      final Result<HeldBill> cancelled = await held.cancel(record.id);

      expect(cancelled.isErr, isTrue);
      expect(
        cancelled.failureOrNull!.message,
        contains('already been resumed'),
      );
    });
  });

  group('two things happening at once', () {
    test('only one of two simultaneous resumes succeeds', () async {
      final HeldBill record = await hold(await pizzaCart());

      final List<Result<HeldBill>> outcomes = await Future.wait(
        <Future<Result<HeldBill>>>[
          held.resume(record.id),
          held.resume(record.id),
        ],
      );

      expect(outcomes.where((Result<HeldBill> r) => r.isOk), hasLength(1));
      expect(outcomes.where((Result<HeldBill> r) => r.isErr), hasLength(1));
      expect(
        (await held.findHeldBill(record.id)).valueOrNull!.status,
        HeldBillStatus.resumed,
      );
    });

    test('a resume and a cancellation cannot both win', () async {
      final HeldBill record = await hold(await pizzaCart());

      final List<Result<HeldBill>> outcomes = await Future.wait(
        <Future<Result<HeldBill>>>[
          held.resume(record.id),
          held.cancel(record.id),
        ],
      );

      expect(outcomes.where((Result<HeldBill> r) => r.isOk), hasLength(1));
      expect(outcomes.where((Result<HeldBill> r) => r.isErr), hasLength(1));
    });

    test('two simultaneous holds of one draft write one bill', () async {
      final HeldBillDraft draft = HeldBillDraft.fromCart(
        cart: await pizzaCart(),
        orderType: OrderType.takeaway,
      );

      final List<Result<HeldBill>> outcomes = await Future.wait(
        <Future<Result<HeldBill>>>[held.hold(draft), held.hold(draft)],
      );

      expect(outcomes.where((Result<HeldBill> r) => r.isOk), hasLength(1));
      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect(await rowsIn(SqliteTables.heldBillLines), 1);
      expect(await rowsIn(SqliteTables.heldBillLineOptions), 1);
      expect((await held.loadHeldBills()).valueOrNull, hasLength(1));
    });

    test('two simultaneous cancellations close the bill once', () async {
      final HeldBill record = await hold(await pizzaCart());

      final List<Result<HeldBill>> outcomes = await Future.wait(
        <Future<Result<HeldBill>>>[
          held.cancel(record.id),
          held.cancel(record.id),
        ],
      );

      expect(outcomes.where((Result<HeldBill> r) => r.isOk), hasLength(1));
      expect(await rowsIn(SqliteTables.heldBills), 1);
    });
  });

  group('a hold that fails part way through', () {
    late FlakyDatabaseFactory factory;
    late SqliteDatabase flakyDatabase;
    late SqliteMenuRepository flakyMenu;
    late SqliteHeldBillRepository flakyHeld;

    setUp(() async {
      factory = FlakyDatabaseFactory();
      flakyDatabase = SqliteDatabase(factory: factory);
      await flakyDatabase.open(path: SqliteDatabase.inMemoryPath);
      flakyMenu = SqliteMenuRepository(database: flakyDatabase);
      flakyHeld = SqliteHeldBillRepository(database: flakyDatabase);
    });

    tearDown(() async {
      factory.allowAllWrites();
      await flakyDatabase.close();
    });

    Future<int> flakyRowsIn(String table) async {
      final List<Map<String, Object?>> rows = await flakyDatabase.database
          .query(table);
      return rows.length;
    }

    test('is reported as a failure', () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        flakyMenu,
      );
      factory.reset();
      // The header lands, and the line after it is refused.
      factory.failAfterWrites = 1;

      final Result<HeldBill> result = await flakyHeld.hold(
        HeldBillDraft.fromCart(cart: cart, orderType: OrderType.takeaway),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<UnexpectedFailure>());
    });

    test('leaves no partial rows behind', () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        flakyMenu,
      );
      factory.reset();
      factory.failAfterWrites = 1;

      await flakyHeld.hold(
        HeldBillDraft.fromCart(cart: cart, orderType: OrderType.takeaway),
      );

      factory.allowAllWrites();

      // The header was written before the failure and is gone with it.
      expect(await flakyRowsIn(SqliteTables.heldBills), 0);
      expect(await flakyRowsIn(SqliteTables.heldBillLines), 0);
      expect(await flakyRowsIn(SqliteTables.heldBillLineOptions), 0);
    });

    test('leaves nothing in the list', () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        flakyMenu,
      );
      factory.reset();
      factory.failAfterWrites = 2;

      await flakyHeld.hold(
        HeldBillDraft.fromCart(cart: cart, orderType: OrderType.takeaway),
      );
      factory.allowAllWrites();

      expect((await flakyHeld.loadHeldBills()).valueOrNull, isEmpty);
    });

    test('can be retried once the fault clears', () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(
        flakyMenu,
      );
      final HeldBillDraft draft = HeldBillDraft.fromCart(
        cart: cart,
        orderType: OrderType.takeaway,
      );
      factory.reset();
      factory.failAfterWrites = 1;

      expect((await flakyHeld.hold(draft)).isErr, isTrue);

      factory.allowAllWrites();

      // Nothing was committed, so the id is free and the same draft goes through.
      final Result<HeldBill> retried = await flakyHeld.hold(draft);

      expect(retried.isOk, isTrue);
      expect(await flakyRowsIn(SqliteTables.heldBills), 1);
      expect(await flakyRowsIn(SqliteTables.heldBillLines), 1);
      expect(await flakyRowsIn(SqliteTables.heldBillLineOptions), 1);
    });
  });
}

/// Rebuilds a menu option with its price doubled.
///
/// Doubling is a change large enough that it would be obvious if it leaked through into a
/// held bill, which is exactly what the repricing tests check does not happen.
class MenuItemOptionUpdate {
  const MenuItemOptionUpdate(this.option);

  final MenuItemOption option;

  MenuItemOption doubled() {
    return option.copyWith(
      price: option.price * 2,
      updatedAt: DateTime.now().toUtc(),
    );
  }
}
