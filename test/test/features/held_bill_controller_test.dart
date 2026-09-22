import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_held_bill_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_summary.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';

/// Holding and resuming as the counter drives it, through the controllers.
///
/// The repository underneath is the real one over a real database, so these tests are
/// about the two rules the controllers own — the cart is emptied only after a hold
/// commits, and a resume never overwrites a bill in progress — rather than about SQL,
/// which `held_bill_repository_test.dart` covers.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteHeldBillRepository held;
  late BillingController billing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    held = SqliteHeldBillRepository(database: database);
    billing = await SeededCart.controller(menu, heldBills: held);
  });

  tearDown(() async {
    billing.dispose();
    await database.close();
  });

  /// Puts one Medium Cheese Pizza with Extra Cheese in the live cart: 250 + 70 = 320.
  Future<void> addPizza(BillingController controller, {int quantity = 1}) =>
      SeededCart.add(
        controller,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
        options: <String>['Extra Cheese'],
        quantity: quantity,
      );

  Future<int> rowsIn(String table) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      table,
    );
    return rows.length;
  }

  group('holding the current bill', () {
    test('an empty cart cannot be held', () async {
      expect(billing.canHold, isFalse);

      final bool wasHeld = await billing.holdCart();

      expect(wasHeld, isFalse);
      expect(await rowsIn(SqliteTables.heldBills), 0);
      // Refused before anything was attempted, so there is nothing to report.
      expect(billing.hasHoldError, isFalse);
    });

    test('a populated cart is held', () async {
      await addPizza(billing);
      expect(billing.canHold, isTrue);

      final bool wasHeld = await billing.holdCart();

      expect(wasHeld, isTrue);
      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect((await held.loadHeldBills()).valueOrNull, hasLength(1));
    });

    test('a successful hold empties the live cart', () async {
      await addPizza(billing, quantity: 2);

      await billing.holdCart();

      expect(billing.cart.isEmpty, isTrue);
      expect(billing.cart.lineCount, 0);
      expect(billing.subtotal.paise, 0);
    });

    test('a successful hold says so', () async {
      await addPizza(billing, quantity: 2);

      await billing.holdCart();

      expect(billing.hasHeldNotice, isTrue);
      expect(billing.heldNotice, contains('1 line'));
      expect(billing.heldNotice, contains('2 items'));
      // The bill that was held, described after the cart it describes has gone.
      expect(billing.heldNotice, contains('640.00'));
      expect(billing.hasHoldError, isFalse);
    });

    test('the confirmation can be dismissed', () async {
      await addPizza(billing);
      await billing.holdCart();

      billing.dismissHeldNotice();

      expect(billing.hasHeldNotice, isFalse);
    });

    test('the order type is carried onto the held bill', () async {
      await addPizza(billing);

      await billing.holdCart(orderType: OrderType.delivery);

      final HeldBillSummary summary =
          (await held.loadHeldBills()).valueOrNull!.single;
      expect(summary.orderType, OrderType.delivery);
    });

    test('holding closes an open item configuration', () async {
      await addPizza(billing);
      // Mid-configuration when the customer walks off, which is exactly when a bill gets
      // held. The draft belongs to the bill being put aside and goes with it.
      await billing.selectCategory(billing.categories.first);
      await billing.selectItem(billing.items.first);
      expect(billing.isConfiguring, isTrue);

      await billing.holdCart();

      expect(billing.isConfiguring, isFalse);
    });

    test('holding creates no sale, no payment and no stock movement', () async {
      await addPizza(billing);

      await billing.holdCart();

      expect(await rowsIn(SqliteTables.orders), 0);
      expect(await rowsIn(SqliteTables.orderItems), 0);
      expect(await rowsIn(SqliteTables.payments), 0);
      expect(await rowsIn(SqliteTables.kotRecords), 0);
      expect(await rowsIn(SqliteTables.stockMovements), 0);
      expect(await rowsIn(SqliteTables.customers), 0);
    });

    test('a hold in flight cannot be started twice', () async {
      await addPizza(billing);

      // Both dispatched before either completes, which is a double tap.
      final List<bool> outcomes = await Future.wait(<Future<bool>>[
        billing.holdCart(),
        billing.holdCart(),
      ]);

      expect(outcomes.where((bool wasHeld) => wasHeld), hasLength(1));
      expect(await rowsIn(SqliteTables.heldBills), 1);
      expect(await rowsIn(SqliteTables.heldBillLines), 1);
    });
  });
}
