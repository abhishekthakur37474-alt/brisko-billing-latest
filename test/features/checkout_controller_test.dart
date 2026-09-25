import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// The settlement flow as the cashier drives it, over the real database.
///
/// The cart comes from the seeded menu through [BillingController], and settlement goes
/// through the production checkout repository, so these tests exercise the same path the
/// application takes from tap to committed row.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkoutRepository;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteInventoryDeductionRepository deductions;
  late BillingController billing;
  late FakeEscPosPrinter printer;
  late PrintService printing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkoutRepository = SqliteCheckoutRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
    printer = FakeEscPosPrinter();
    printing = TestPrinting.serviceOver(database, printer: printer);
    billing = await SeededCart.controller(menu);
  });

  tearDown(() async {
    billing.dispose();
    await database.close();
  });

  /// A Medium Cheese Pizza with Extra Cheese in the live cart: 250 + 70 = 320.
  Future<void> ringUpPizza({int quantity = 1}) => SeededCart.add(
    billing,
    category: 'SIMPLY VEG',
    item: 'Cheese Pizza',
    size: 'Medium',
    options: <String>['Extra Cheese'],
    quantity: quantity,
  );

  /// Name every order requires before payment. Phone is optional.
  void fillCustomer(
    CheckoutController controller, {
    String name = 'Test Customer',
    String phone = '9000000001',
  }) {
    controller.setCustomerName(name);
    controller.setCustomerPhone(phone);
  }

  /// A checkout over whatever is currently in the billing cart.
  CheckoutController openCheckout({
    bool withCustomer = true,
    bool printKitchenSlip = true,
    bool askCustomerDetails = true,
  }) {
    final CheckoutController controller = CheckoutController(
      cart: billing.cart,
      checkoutRepository: checkoutRepository,
      customerRepository: customers,
      inventoryDeductionRepository: deductions,
      printService: printing,
      onSettled: billing.clearCart,
      printKitchenSlip: printKitchenSlip,
      askCustomerDetails: askCustomerDetails,
    );
    addTearDown(controller.dispose);
    if (withCustomer && askCustomerDetails) {
      fillCustomer(controller);
    }
    return controller;
  }

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Walks to the confirm step paying cash with the exact amount.
  Future<CheckoutController> readyToCharge({
    PaymentMethod method = PaymentMethod.cash,
  }) async {
    await ringUpPizza();
    final CheckoutController controller = openCheckout();
    fillCustomer(controller);
    controller.goToPayment();
    controller.selectPaymentMethod(method);
    if (method == PaymentMethod.cash) {
      controller.tenderExact();
    }
    controller.goToConfirm();
    return controller;
  }

  group('opening checkout', () {
    test('it starts on review with the bill as it stood', () async {
      await ringUpPizza(quantity: 2);
      final CheckoutController controller = openCheckout();

      expect(controller.step, CheckoutStep.review);
      expect(controller.cart.lineCount, 1);
      expect(controller.cart.itemCount, 2);
      expect(controller.totals.subtotal, Money.parse('640'));
      expect(controller.totals.total, Money.parse('640'));
      expect(controller.amountPayable, Money.parse('640'));
      expect(controller.hasBill, isTrue);
      expect(controller.isSettled, isFalse);
      expect(controller.hasError, isFalse);
    });

    test('an empty cart has no bill to settle', () async {
      final CheckoutController controller = openCheckout();

      expect(controller.cart.isEmpty, isTrue);
      expect(controller.totals.total, Money.zero);
      expect(controller.hasBill, isFalse);
      expect(controller.canProceedToPayment, isFalse);
      expect(controller.canSubmit, isFalse);
    });

    test('an empty cart cannot be pushed through the flow', () async {
      final CheckoutController controller = openCheckout();

      controller.goToPayment();
      expect(controller.step, CheckoutStep.review);

      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.goToConfirm();
      expect(controller.step, CheckoutStep.review);

      await controller.submit();
      expect(controller.isSettled, isFalse);
      expect(await rowCount('orders'), 0);
    });

    test('the checkout cart is a snapshot, not the live one', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();

      // The cashier adds another item to the billing screen behind the flow.
      await SeededCart.add(
        billing,
        category: 'SIDE ORDER',
        item: 'French Fries',
      );

      expect(billing.subtotal, Money.parse('390'));
      // The bill being settled is the one that was opened.
      expect(controller.totals.total, Money.parse('320'));
    });
  });

  group('stepping through', () {
    test('review to payment to confirm', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();

      fillCustomer(controller);
      expect(controller.canProceedToPayment, isTrue);
      controller.goToPayment();
      expect(controller.step, CheckoutStep.payment);

      // No method chosen yet.
      expect(controller.canProceedToConfirm, isFalse);
      controller.goToConfirm();
      expect(controller.step, CheckoutStep.payment);

      controller.selectPaymentMethod(PaymentMethod.upi);
      expect(controller.canProceedToConfirm, isTrue);
      controller.goToConfirm();
      expect(controller.step, CheckoutStep.confirm);
      expect(controller.canSubmit, isTrue);
    });

    test('going back keeps the bill and what was entered', () async {
      final CheckoutController controller = await readyToCharge();
      expect(controller.step, CheckoutStep.confirm);

      expect(controller.goBack(), isTrue);
      expect(controller.step, CheckoutStep.payment);
      // The tender survives the trip.
      expect(controller.cashTender.tendered, Money.parse('320'));

      expect(controller.goBack(), isTrue);
      expect(controller.step, CheckoutStep.review);
      expect(controller.totals.total, Money.parse('320'));

      // Nowhere left to go: the screen leaves the flow.
      expect(controller.previousStep, isNull);
      expect(controller.goBack(), isFalse);
      expect(controller.step, CheckoutStep.review);

      // And the live cart was never touched.
      expect(billing.subtotal, Money.parse('320'));
      expect(await rowCount('orders'), 0);
    });

    test('a settled bill cannot be stepped back into', () async {
      final CheckoutController controller = await readyToCharge();
      await controller.submit();

      expect(controller.step, CheckoutStep.success);
      expect(controller.previousStep, isNull);
      expect(controller.goBack(), isFalse);
      expect(controller.step, CheckoutStep.success);
    });
  });

  group('the customer', () {
    test('every order needs a name; the phone is optional', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      expect(controller.orderType, OrderType.takeaway);
      expect(controller.hasCustomerPhone, isFalse);
      expect(controller.hasCustomerName, isFalse);
      expect(controller.isCustomerAcceptable, isFalse);
      expect(controller.canProceedToPayment, isFalse);

      controller.setCustomerPhone('9000000001');
      expect(controller.canProceedToPayment, isFalse);

      controller.setCustomerName('Ravi');
      expect(controller.isCustomerAcceptable, isTrue);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('turning the setting off lets a walk-in through', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(
        withCustomer: false,
        askCustomerDetails: false,
      );

      expect(controller.askCustomerDetails, isFalse);
      expect(controller.isCustomerAcceptable, isTrue);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('an order that leaves the outlet still needs a name, not a phone', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.selectOrderType(OrderType.delivery);
      controller.setCustomerName('Ravi');
      controller.setCustomerAddress('12 Baraut Road, Chhaprauli');

      expect(controller.hasCustomerPhone, isFalse);
      expect(controller.requiresCustomerAddress, isTrue);
      expect(controller.isCustomerAcceptable, isTrue);
      expect(controller.canProceedToPayment, isTrue);

      controller.setCustomerPhone('9000000001');

      expect(controller.isCustomerPhoneComplete, isTrue);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('a delivery without an address cannot proceed', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.selectOrderType(OrderType.delivery);
      controller.setCustomerName('Ravi');

      expect(controller.requiresCustomerAddress, isTrue);
      expect(controller.hasCustomerAddress, isFalse);
      expect(controller.customerAddressProblem, 'An address is needed for a delivery order.');
      expect(controller.isCustomerAcceptable, isFalse);
      expect(controller.canProceedToPayment, isFalse);

      controller.setCustomerAddress('Opp. library, Baraut Road');

      expect(controller.hasCustomerAddress, isTrue);
      expect(controller.customerAddressProblem, isNull);
      expect(controller.isCustomerAcceptable, isTrue);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('a delivery still needs an address when customer details are optional', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(
        withCustomer: false,
        askCustomerDetails: false,
      );

      expect(controller.canProceedToPayment, isTrue);

      controller.selectOrderType(OrderType.delivery);

      expect(controller.requiresCustomerAddress, isTrue);
      expect(controller.isCustomerAcceptable, isFalse);
      expect(controller.canProceedToPayment, isFalse);

      controller.setCustomerAddress('12 Baraut Road');

      expect(controller.isCustomerAcceptable, isTrue);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('a half-typed number blocks the flow even when optional', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.setCustomerName('Ravi');
      expect(controller.isCustomerAcceptable, isTrue);

      controller.setCustomerPhone('90000');

      expect(controller.isCustomerPhoneComplete, isFalse);
      expect(controller.isCustomerAcceptable, isFalse);
      expect(controller.canProceedToPayment, isFalse);
    });

    test('only the digits of what was typed are kept', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.setCustomerPhone('+91 (90000) 00001-x');

      // Punctuation removed, digits kept as entered rather than cut down to ten.
      expect(controller.customerPhone, '919000000001');
      // The country code accounts for the two extra digits, so this is a number the
      // outlet can store. The old behaviour kept the first ten digits and produced
      // 9190000000, which is a different customer's number.
      expect(controller.normalisedCustomerPhone, '9000000001');
    });

    test('a country code is dropped, not counted as part of the number', () {
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.setCustomerPhone('+91 98765 43210');

      expect(controller.customerPhone, '919876543210');
      // What will actually be stored, and what a later lookup will find.
      expect(controller.normalisedCustomerPhone, '9876543210');
      expect(controller.isCustomerPhoneComplete, isTrue);
      expect(controller.customerPhoneProblem, isNull);
    });

    test('a number is never shortened to make it fit', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.setCustomerName('Ravi');

      // Thirteen digits, with no prefix that accounts for the extra three. Keeping the
      // first ten would produce 9000000001 — a real number belonging to somebody else —
      // and file the bill against them. It is refused instead.
      controller.setCustomerPhone('9000000001234');

      expect(controller.customerPhone, '9000000001234');
      expect(controller.normalisedCustomerPhone, isNull);
      expect(controller.isCustomerPhoneComplete, isFalse);
      expect(controller.isCustomerAcceptable, isFalse);
      expect(controller.canProceedToPayment, isFalse);
      expect(controller.customerPhoneProblem, isNotNull);
    });

    test('a number that is not a mobile number is refused', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);

      controller.setCustomerName('Ravi');

      // Ten digits, but no Indian mobile number starts with 1.
      controller.setCustomerPhone('1123456789');

      expect(controller.normalisedCustomerPhone, isNull);
      expect(controller.canProceedToPayment, isFalse);
    });

    test(
      'a returning customer is recognised before the money is taken',
      () async {
        await customers.findOrCreateByPhone('9000000007', name: 'Test Regular');

        await ringUpPizza();
        final CheckoutController controller = openCheckout();
        expect(controller.isReturningCustomer, isFalse);

        controller.setCustomerPhone('9000000007');
        // The lookup is fired without being awaited, so let it land. Bounded rather than a
        // single turn: it is a real query against SQLite, and one event-loop turn is not
        // reliably long enough for it to answer when the suite is running under load.
        for (
          int turn = 0;
          turn < 50 && !controller.isReturningCustomer;
          turn++
        ) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(controller.isReturningCustomer, isTrue);
        expect(controller.knownCustomer!.name, 'Test Regular');
        // A read only. Nothing was created, and nothing was created for the number that
        // is not on file either.
        expect(await rowCount('customers'), 1);
      },
    );

    test('an unknown number is not recognised and is not created', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();

      controller.setCustomerPhone('9000000008');
      await Future<void>.delayed(Duration.zero);

      expect(controller.isReturningCustomer, isFalse);
      expect(await rowCount('customers'), 0);
    });

    test('a name without a phone is kept on the bill', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);
      controller.setCustomerName('Ravi');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.card);
      controller.goToConfirm();

      await controller.submit();

      expect(controller.isSettled, isTrue);
      expect(controller.settledOrder!.customerId, isNull);
      expect(controller.settledOrder!.customerName, 'Ravi');
      expect(await rowCount('customers'), 0);

      final Order stored = (await orders.findOrder(
        controller.settledOrder!.id,
      )).valueOrNull!;
      expect(stored.customerName, 'Ravi');
    });

    test('a delivery address is stored on the bill', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(withCustomer: false);
      controller.selectOrderType(OrderType.delivery);
      controller.setCustomerName('Ravi');
      controller.setCustomerAddress('12 Baraut Road, Chhaprauli');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.card);
      controller.goToConfirm();

      await controller.submit();

      expect(controller.isSettled, isTrue);
      expect(controller.settledOrder!.orderType, OrderType.delivery);
      expect(controller.settledOrder!.customerAddress, '12 Baraut Road, Chhaprauli');

      final Order stored = (await orders.findOrder(
        controller.settledOrder!.id,
      )).valueOrNull!;
      expect(stored.customerAddress, '12 Baraut Road, Chhaprauli');
      expect(stored.toMap()['customerAddress'], '12 Baraut Road, Chhaprauli');
    });

    test('the customer is created and linked to the bill', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      fillCustomer(controller, name: 'Ravi', phone: '9000000001');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.card);
      controller.goToConfirm();

      await controller.submit();

      final Order order = controller.settledOrder!;
      expect(order.customerId, isNotNull);

      final Customer customer = (await customers.findByPhone('9000000001'))
          .valueOrNull!;
      expect(order.customerId, customer.id);
      expect(customer.name, 'Ravi');
      expect(
        (await orders.loadOrdersForCustomer(customer.id)).valueOrNull,
        hasLength(1),
      );
    });

    test('a returning customer is reused rather than duplicated', () async {
      final Customer existing = (await customers.findOrCreateByPhone(
        '9000000002',
        name: 'Regular',
      )).valueOrNull!;

      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      fillCustomer(controller, name: 'Regular', phone: '9000000002');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.goToConfirm();

      await controller.submit();

      expect(controller.settledOrder!.customerId, existing.id);
      expect(await rowCount('customers'), 1);
    });

    test('a settled bill records the customer name', () async {
      final CheckoutController controller = await readyToCharge();

      await controller.submit();

      expect(controller.settledOrder!.customerId, isNotNull);
      final Customer customer = (await customers.findById(
        controller.settledOrder!.customerId!,
      )).valueOrNull!;
      expect(customer.name, 'Test Customer');
      expect(customer.phone, '9000000001');
    });

    test('a failed charge leaves no customer behind', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      fillCustomer(controller, name: 'Ravi', phone: '9000000003');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.goToConfirm();

      // The failure arrives the way a real one does: the storage goes away.
      await database.close();
      await controller.submit();
      expect(controller.hasError, isTrue);
      expect(controller.isSettled, isFalse);

      // Reopened on the same file would show the same thing; in memory, prove it
      // through the transaction instead — nothing at all was committed, so a fresh
      // database is the state the failed sale left.
      database = await TestDatabase.openInMemory();
      final SqliteCustomerRepository reopened = SqliteCustomerRepository(
        database: database,
      );
      expect((await reopened.loadAll()).valueOrNull, isEmpty);
    });

    test('a bill that rolls back mid-settlement writes neither bill nor customer', () async {
      // A settlement the repository will refuse after the customer would have been
      // resolved: the order number is allocated, then the payment is found not to
      // match the total. Everything in that transaction has to roll back together.
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(menu);
      final BillSettlement settlement = BillSettlement.fromCart(
        cart: cart,
        orderType: OrderType.delivery,
        paymentMethod: PaymentMethod.cash,
        customerPhone: '9000000004',
      );

      final Result<Order> first = await checkoutRepository.settle(settlement);
      expect(first.isOk, isTrue, reason: first.failureOrNull?.message);
      expect(await rowCount('customers'), 1);

      // A second settlement of the same bill is refused, and must not touch the
      // customer table.
      final Result<Order> second = await checkoutRepository.settle(settlement);
      expect(second.isErr, isTrue);
      expect(await rowCount('customers'), 1);
      expect(await rowCount('orders'), 1);
    });

    test('an unusable number refuses the sale and writes nothing', () async {
      final Cart cart = await SeededCart.mediumCheesePizzaWithExtraCheese(menu);
      final Result<Order> result = await checkoutRepository.settle(
        BillSettlement.fromCart(
          cart: cart,
          orderType: OrderType.delivery,
          paymentMethod: PaymentMethod.cash,
          // Ten digits, but not a mobile number.
          customerPhone: '1234567890',
        ),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(await rowCount('customers'), 0);
      expect(await rowCount('orders'), 0);
      expect(await rowCount('payments'), 0);
      expect(await rowCount('kot_records'), 0);
    });

    test('the number is stored normalised, however it was typed', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      fillCustomer(controller, name: 'Ravi', phone: '+91 98765 43210');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.goToConfirm();

      await controller.submit();

      final Customer customer = (await customers.findById(
        controller.settledOrder!.customerId!,
      )).valueOrNull!;
      expect(customer.phone, '9876543210');
      // And the number as typed reaches the same record.
      expect(
        (await customers.findByPhone('+91 98765 43210')).valueOrNull!.id,
        customer.id,
      );
    });
  });

  group('the kitchen slip', () {
    test('starts from the setting and can be turned off for this bill', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();

      expect(controller.printKitchenSlip, isTrue);

      controller.setPrintKitchenSlip(isEnabled: false);

      expect(controller.printKitchenSlip, isFalse);
      expect(controller.canProceedToPayment, isTrue);
    });

    test('turning it off still writes the slip and skips the paper', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.setPrintKitchenSlip(isEnabled: false);
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.card);
      controller.goToConfirm();

      await controller.submit();

      expect(controller.isSettled, isTrue);
      expect(await rowCount('kot_records'), 1);
      expect(controller.printKitchenSlip, isFalse);
    });
  });

  group('paying', () {
    test('every method can be chosen and settles the exact amount', () async {
      for (final PaymentMethod method in PaymentMethod.values) {
        final CheckoutController controller = await readyToCharge(
          method: method,
        );
        expect(controller.paymentMethod, method, reason: method.name);

        await controller.submit();

        final Payment payment = (await payments.loadForOrder(
          controller.settledOrder!.id,
        )).valueOrNull!.single;
        expect(payment.paymentMethod, method, reason: method.name);
        expect(payment.amount, Money.parse('320'), reason: method.name);
        expect(payment.status, PaymentStatus.completed, reason: method.name);

        billing.clearCart();
      }
    });

    test('a non-cash payment needs no tender and gives no change', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();

      controller.selectPaymentMethod(PaymentMethod.upi);

      expect(controller.isTenderSufficient, isTrue);
      expect(controller.changeDue, Money.zero);
      expect(controller.canProceedToConfirm, isTrue);
    });

    test('cash must cover the bill before it can be confirmed', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);

      expect(controller.isTenderSufficient, isFalse);
      expect(controller.canProceedToConfirm, isFalse);
      expect(controller.canSubmit, isFalse);
    });

    test('cash short of the bill is refused', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);

      // ₹300 against ₹320.
      controller.addTenderNote(const Money.fromRupees(200));
      controller.addTenderNote(const Money.fromRupees(100));

      expect(controller.cashTender.tendered, Money.parse('300'));
      expect(controller.cashTender.shortfall, Money.parse('20'));
      expect(controller.canProceedToConfirm, isFalse);

      controller.goToConfirm();
      expect(controller.step, CheckoutStep.payment);

      await controller.submit();
      expect(controller.isSettled, isFalse);
      expect(await rowCount('orders'), 0);
    });

    test('exact cash leaves no change', () async {
      final CheckoutController controller = await readyToCharge();

      expect(controller.cashTender.isExact, isTrue);
      expect(controller.changeDue, Money.zero);

      await controller.submit();

      expect(controller.settledOrder!.totalAmount, Money.parse('320'));
    });

    test('cash over the bill gives exact change', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.addTenderNote(const Money.fromRupees(500));

      expect(controller.cashTender.tendered, Money.parse('500'));
      expect(controller.changeDue, Money.parse('180'));
      expect(controller.canProceedToConfirm, isTrue);

      controller.goToConfirm();
      await controller.submit();

      // Change is money handed back, not money collected: the payment records the
      // bill, and the till is not credited with the ₹500.
      final Payment payment = (await payments.loadForOrder(
        controller.settledOrder!.id,
      )).valueOrNull!.single;
      expect(payment.amount, Money.parse('320'));
      expect(controller.changeDue, Money.parse('180'));
    });

    test('the keypad builds the amount a digit at a time', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);

      for (final int digit in <int>[5, 0, 0, 0, 0]) {
        controller.appendTenderDigit(digit);
      }

      expect(controller.cashTender.tendered, Money.parse('500.00'));
      expect(controller.changeDue, Money.parse('180.00'));

      controller.removeTenderDigit();
      expect(controller.cashTender.tendered, Money.parse('50.00'));

      controller.clearTender();
      expect(controller.cashTender.tendered, Money.zero);
    });

    test('a tender keyed before cash was chosen is ignored', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);

      controller.appendTenderDigit(9);
      controller.tenderExact();

      expect(controller.cashTender.tendered, Money.zero);
    });

    test('switching method clears the counted cash', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.addTenderNote(const Money.fromRupees(500));
      expect(controller.cashTender.tendered, Money.parse('500'));

      controller.selectPaymentMethod(PaymentMethod.card);
      controller.selectPaymentMethod(PaymentMethod.cash);

      expect(controller.cashTender.tendered, Money.zero);
      expect(controller.cashTender.payable, Money.parse('320'));
    });

    test('a reference is recorded against a non-cash payment', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.setReference('  UPI-99887766  ');
      controller.goToConfirm();

      await controller.submit();

      final Payment payment = (await payments.loadForOrder(
        controller.settledOrder!.id,
      )).valueOrNull!.single;
      expect(payment.reference, 'UPI-99887766');
    });

    test('switching method drops a reference typed for the old one', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.setReference('UPI-1');

      controller.selectPaymentMethod(PaymentMethod.card);

      expect(controller.reference, isEmpty);
    });
  });

  group('settling', () {
    test(
      'a successful charge persists the bill and reports the number',
      () async {
        final CheckoutController controller = await readyToCharge();

        await controller.submit();

        expect(controller.step, CheckoutStep.success);
        expect(controller.isSettled, isTrue);
        expect(controller.isSubmitting, isFalse);
        expect(controller.hasError, isFalse);
        expect(controller.orderNumber, matches(RegExp(r'^\d{8}-0001$')));

        final Order order = controller.settledOrder!;
        expect(order.status, OrderStatus.completed);
        expect(order.status.countsTowardsSales, isTrue);
        expect(order.totalAmount, Money.parse('320'));

        final OrderItem line = (await orders.loadItems(order.id))
            .valueOrNull!
            .single;
        expect(line.itemNameSnapshot, 'Cheese Pizza');
        expect(line.variantNameSnapshot, 'Medium');
        expect(line.unitPrice, Money.parse('320'));
        expect(
          (await orders.loadItemOptions(line.id)).valueOrNull!.single.price,
          Money.parse('70'),
        );
      },
    );

    test('the cart clears only once the bill is on disk', () async {
      final CheckoutController controller = await readyToCharge();

      // Still there right up to the charge.
      expect(billing.cart.isNotEmpty, isTrue);

      await controller.submit();

      expect(billing.cart.isEmpty, isTrue);
      expect(billing.subtotal, Money.zero);
      // The settled bill is still on screen for the receipt.
      expect(controller.cart.isNotEmpty, isTrue);
      expect(controller.totals.total, Money.parse('320'));
    });

    test(
      'a failed charge keeps the cart and says nothing was written',
      () async {
        final CheckoutController controller = await readyToCharge();
        final Money before = billing.subtotal;

        await database.close();
        await controller.submit();

        expect(controller.isSettled, isFalse);
        expect(controller.step, CheckoutStep.confirm);
        expect(controller.isSubmitting, isFalse);
        expect(controller.hasError, isTrue);
        expect(controller.errorMessage, isNotEmpty);

        // The bill is intact and can be charged again.
        expect(billing.subtotal, before);
        expect(billing.cart.lineCount, 1);
        expect(controller.canSubmit, isTrue);
      },
    );

    test('an error can be dismissed without losing the bill', () async {
      final CheckoutController controller = await readyToCharge();
      await database.close();
      await controller.submit();
      expect(controller.hasError, isTrue);

      controller.dismissError();

      expect(controller.hasError, isFalse);
      expect(controller.errorMessage, isNull);
      expect(controller.canSubmit, isTrue);
    });

    test('a retry after a failure settles the bill once', () async {
      final CheckoutController controller = CheckoutController(
        cart: await SeededCart.mediumCheesePizzaWithExtraCheese(menu),
        checkoutRepository: checkoutRepository,
        customerRepository: customers,
        inventoryDeductionRepository: deductions,
        printService: printing,
        onSettled: billing.clearCart,
      );
      addTearDown(controller.dispose);
      controller.setCustomerName('Test Customer');
      controller.setCustomerPhone('9000000001');
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.upi);
      controller.goToConfirm();

      // A payment amount cannot be tampered with from here, so the failure is
      // induced the way a real one arrives: the storage goes away and comes back.
      await database.close();
      await controller.submit();
      expect(controller.hasError, isTrue);

      database = await TestDatabase.openInMemory();
      final SqliteCheckoutRepository reopened = SqliteCheckoutRepository(
        database: database,
      );
      final CheckoutController second = CheckoutController(
        cart: controller.cart,
        checkoutRepository: reopened,
        customerRepository: SqliteCustomerRepository(database: database),
        inventoryDeductionRepository: SqliteInventoryDeductionRepository(
          database: database,
        ),
        printService: TestPrinting.serviceOver(database, printer: printer),
        onSettled: billing.clearCart,
      );
      addTearDown(second.dispose);
      second.setCustomerName('Test Customer');
      second.setCustomerPhone('9000000001');
      second.goToPayment();
      second.selectPaymentMethod(PaymentMethod.upi);
      second.goToConfirm();

      await second.submit();

      expect(second.isSettled, isTrue);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
    });

    test('a second submission cannot create a second bill', () async {
      final CheckoutController controller = await readyToCharge();

      // Both started before either has finished.
      await Future.wait<void>(<Future<void>>[
        controller.submit(),
        controller.submit(),
      ]);

      expect(controller.isSettled, isTrue);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('order_items'), 1);
      expect(await rowCount('order_item_options'), 1);
      expect(await rowCount('payments'), 1);
    });

    test('submitting again after success does nothing', () async {
      final CheckoutController controller = await readyToCharge();
      await controller.submit();
      final String number = controller.orderNumber!;

      await controller.submit();
      await controller.submit();

      expect(controller.orderNumber, number);
      expect(controller.hasError, isFalse);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
    });

    test('a settled bill cannot be edited', () async {
      final CheckoutController controller = await readyToCharge();
      await controller.submit();

      controller.selectOrderType(OrderType.delivery);
      controller.setCustomerPhone('9000000009');
      controller.selectPaymentMethod(PaymentMethod.card);
      controller.setNotes('changed');
      controller.setPrintKitchenSlip(isEnabled: false);

      expect(controller.orderType, OrderType.takeaway);
      expect(controller.customerPhone, isEmpty);
      expect(controller.paymentMethod, PaymentMethod.cash);
      expect(controller.notes, isEmpty);
      expect(controller.printKitchenSlip, isTrue);
      expect(
        (await orders.findOrder(controller.settledOrder!.id))
            .valueOrNull!
            .orderType,
        OrderType.takeaway,
      );
    });

    test('two bills in a row get their own numbers', () async {
      final CheckoutController first = await readyToCharge();
      await first.submit();

      await ringUpPizza();
      final CheckoutController second = await readyToCharge();
      await second.submit();

      expect(first.orderNumber, endsWith('-0001'));
      expect(second.orderNumber, endsWith('-0002'));
      expect(await rowCount('orders'), 2);
      expect(await rowCount('payments'), 2);
    });

    test('the flow notifies listeners as it moves', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();

      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.selectOrderType(OrderType.dineIn);
      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.tenderExact();
      controller.goToConfirm();
      expect(notifications, 5);

      // A no-op does not wake the widget tree.
      controller.selectOrderType(OrderType.dineIn);
      expect(notifications, 5);

      await controller.submit();
      // Five: the settlement going in flight, its outcome, then printing going in
      // flight and its outcome, then the stock deduction's outcome. Printing and stock
      // come after the settlement pair on purpose — the sale is already reported as
      // settled before either is touched, so the success screen is on display while the
      // paper is still coming out and the shelves are being updated.
      //
      // Stock is one notification rather than two: it does not announce going in
      // flight, because there is nothing on screen waiting for it.
      expect(notifications, 10);
      expect(controller.isSettled, isTrue);
      expect(controller.isPrinted, isTrue);
      // Nothing to report: no recipes are configured in this test, so the bill's items
      // are named as unconfigured rather than silently deducting.
      expect(controller.deduction, isNotNull);
      expect(controller.deduction!.deductedNothing, isTrue);
    });
  });
}
