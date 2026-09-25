import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_totals.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:brisko_billing/features/billing/domain/models/cash_tender.dart';
import 'package:brisko_billing/features/billing/domain/models/checkout_transition.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item_option.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

/// The arithmetic and the rules of settlement, with no database involved.
///
/// Amounts here are synthetic on purpose. These tests are about exactness for any
/// value, including the sub-rupee ones the printed menu happens not to contain, and
/// about the shape of the rows a cart turns into. Settlement against the real seeded
/// menu is covered by the checkout repository and controller tests.
void main() {
  MenuItem itemPriced(String price) =>
      Fixtures.menuItem(categoryId: 'cat-test', basePrice: price);

  Cart cartOf(List<CartLine> lines) => Cart(lines);

  CartLine lineOf({
    required String id,
    required MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemOption> options = const <MenuItemOption>[],
    int quantity = 1,
  }) => CartLine.fromSelection(
    id: id,
    item: item,
    variant: variant,
    options: options,
    quantity: quantity,
  );

  group('BillTotals', () {
    test('the total of a plain bill is its subtotal', () {
      final Cart cart = cartOf(<CartLine>[
        lineOf(id: 'l1', item: itemPriced('250.00')),
        lineOf(id: 'l2', item: itemPriced('70.00')),
      ]);

      final BillTotals totals = BillTotals.fromCart(cart);

      expect(totals.subtotal, Money.parse('320'));
      expect(totals.total, Money.parse('320'));
      expect(totals.isPayable, isTrue);
    });

    test('a cart on its own carries no discount and no tax', () {
      // `BillTotals.fromCart` is what a cart alone can answer. A discount is entered at
      // settlement and a GST rate comes from the outlet's configuration, so neither is the
      // cart's to know, and both must be exactly zero here rather than guessed at.
      //
      // This is also the shape every bill had before step 14, which is why an outlet that
      // configures no rate still settles exactly this bill. The discounted and taxed cases
      // live in `gst_discount_domain_test.dart`.
      final BillTotals totals = BillTotals.fromCart(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('250.00'))]),
      );

      expect(totals.discount, Money.zero);
      expect(totals.tax, Money.zero);
      expect(totals.hasAdjustments, isFalse);
    });

    test('an adjustment moves the total in the right direction', () {
      const BillTotals totals = BillTotals(
        subtotal: Money.fromPaise(32000),
        discount: Money.fromPaise(2000),
        tax: Money.fromPaise(1600),
      );

      // 320.00 - 20.00 + 16.00
      expect(totals.total, const Money.fromPaise(31600));
      expect(totals.hasAdjustments, isTrue);
    });

    test('the total is exact at sub-rupee amounts', () {
      final BillTotals totals = BillTotals.fromCart(
        cartOf(<CartLine>[
          lineOf(id: 'l1', item: itemPriced('99.99'), quantity: 3),
        ]),
      );

      expect(totals.total.paise, 29997);
    });

    test('an empty bill is not payable', () {
      final BillTotals totals = BillTotals.fromCart(const Cart.empty());

      expect(totals.subtotal, Money.zero);
      expect(totals.total, Money.zero);
      expect(totals.isPayable, isFalse);
    });
  });

  group('CashTender', () {
    const Money payable = Money.fromPaise(32000);
    const CashTender empty = CashTender(payable: payable);

    test('nothing tendered is short by the whole bill', () {
      expect(empty.hasTender, isFalse);
      expect(empty.isSufficient, isFalse);
      expect(empty.change, Money.zero);
      expect(empty.shortfall, payable);
    });

    test('digits shift the amount one decimal place at a time', () {
      // 3, 2, 0, 0 keys in ₹32.00 the way a cash keypad does.
      final CashTender three = empty.appendDigit(3);
      final CashTender thirtyTwo = three.appendDigit(2);
      final CashTender threeTwenty = thirtyTwo.appendDigit(0);
      final CashTender thirtyTwoRupees = threeTwenty.appendDigit(0);

      expect(three.tendered.paise, 3);
      expect(thirtyTwo.tendered.paise, 32);
      expect(threeTwenty.tendered.paise, 320);
      expect(thirtyTwoRupees.tendered, Money.parse('32.00'));
    });

    test('a five hundred rupee note is keyed in as six digits', () {
      CashTender tender = empty;
      for (final int digit in <int>[5, 0, 0, 0, 0]) {
        tender = tender.appendDigit(digit);
      }

      expect(tender.tendered, Money.parse('500.00'));
    });

    test('exact payment leaves no change', () {
      final CashTender tender = empty.exact();

      expect(tender.tendered, payable);
      expect(tender.isExact, isTrue);
      expect(tender.isSufficient, isTrue);
      expect(tender.change, Money.zero);
      expect(tender.shortfall, Money.zero);
    });

    test('overpayment gives exact change', () {
      // ₹500 against a ₹320 bill.
      final CashTender tender = empty.addNote(const Money.fromRupees(500));

      expect(tender.isSufficient, isTrue);
      expect(tender.change, Money.parse('180.00'));
      expect(tender.change.paise, 18000);
    });

    test('change is exact to the paisa', () {
      const CashTender awkward = CashTender(
        payable: Money.fromPaise(29997),
        tendered: Money.fromPaise(30000),
      );

      expect(awkward.change.paise, 3);
    });

    test('underpayment is not sufficient and reports the shortfall', () {
      final CashTender tender = empty.addNote(const Money.fromRupees(300));

      expect(tender.isSufficient, isFalse);
      expect(tender.shortfall, Money.parse('20.00'));
      // Never negative on screen: a negative change reads as money owed back.
      expect(tender.change, Money.zero);
      expect(tender.change.isNegative, isFalse);
    });

    test('notes accumulate', () {
      final CashTender tender = empty
          .addNote(const Money.fromRupees(200))
          .addNote(const Money.fromRupees(100))
          .addNote(const Money.fromRupees(20));

      expect(tender.tendered, Money.parse('320.00'));
      expect(tender.isExact, isTrue);
    });

    test('a digit can be taken back', () {
      final CashTender tender = empty
          .appendDigit(5)
          .appendDigit(0)
          .appendDigit(0)
          .removeLastDigit();

      expect(tender.tendered.paise, 50);
    });

    test('deleting past the start leaves zero rather than going negative', () {
      final CashTender tender = empty.removeLastDigit().removeLastDigit();

      expect(tender.tendered, Money.zero);
    });

    test('clearing keeps the bill and drops the tender', () {
      final CashTender tender = empty.exact().cleared();

      expect(tender.payable, payable);
      expect(tender.tendered, Money.zero);
    });

    test('a stuck key cannot run the tender away', () {
      CashTender tender = empty;
      for (int press = 0; press < 20; press++) {
        tender = tender.appendDigit(9);
      }

      expect(
        tender.tendered.paise,
        lessThanOrEqualTo(CashTender.maxTenderedPaise),
      );
      expect(tender.tendered.paise, CashTender.maxTenderedPaise);
    });

    test('a note that would exceed the ceiling is ignored', () {
      const CashTender high = CashTender(
        payable: payable,
        tendered: Money.fromPaise(CashTender.maxTenderedPaise),
      );

      expect(high.addNote(const Money.fromRupees(500)), high);
    });

    test('anything that is not a single digit is a bug', () {
      expect(() => empty.appendDigit(10), throwsArgumentError);
      expect(() => empty.appendDigit(-1), throwsArgumentError);
    });

    test('every offered denomination is a real note', () {
      expect(
        CashTender.denominations.map((Money note) => note.toDecimalString()),
        <String>['10.00', '20.00', '50.00', '100.00', '200.00', '500.00'],
      );
    });
  });

  group('CheckoutTransition', () {
    test('settlement moves a bill from draft to completed', () {
      expect(CheckoutTransition.startingOrderStatus, OrderStatus.draft);
      expect(CheckoutTransition.settledOrderStatus, OrderStatus.completed);
      expect(
        CheckoutTransition.isSettlement(
          OrderStatus.draft,
          OrderStatus.completed,
        ),
        isTrue,
      );
    });

    test('no other move is the settlement transition', () {
      expect(
        CheckoutTransition.isSettlement(
          OrderStatus.confirmed,
          OrderStatus.completed,
        ),
        isFalse,
      );
      expect(
        CheckoutTransition.isSettlement(
          OrderStatus.draft,
          OrderStatus.cancelled,
        ),
        isFalse,
      );
      expect(
        CheckoutTransition.isSettlement(
          OrderStatus.completed,
          OrderStatus.draft,
        ),
        isFalse,
      );
    });

    test('a settled bill counts towards sales and is closed', () {
      expect(CheckoutTransition.settledOrderStatus.countsTowardsSales, isTrue);
      expect(CheckoutTransition.settledOrderStatus.isClosed, isTrue);
    });

    test('the payment is recorded as settled, so it counts as collected', () {
      expect(CheckoutTransition.settledPaymentStatus, PaymentStatus.completed);
      expect(CheckoutTransition.settledPaymentStatus.isSettled, isTrue);
    });

    test('an unsettled bill would not count towards sales', () {
      expect(
        CheckoutTransition.startingOrderStatus.countsTowardsSales,
        isFalse,
      );
    });
  });

  group('BillSettlement', () {
    final DateTime at = DateTime.utc(2026, 9, 11, 10, 30);

    BillSettlement settlementFor(
      Cart cart, {
      OrderType orderType = OrderType.takeaway,
      PaymentMethod method = PaymentMethod.cash,
      String? customerName,
      String? customerPhone,
      String? customerAddress,
      String? reference,
      String? notes,
    }) => BillSettlement.fromCart(
      cart: cart,
      orderType: orderType,
      paymentMethod: method,
      customerName: customerName,
      customerPhone: customerPhone,
      customerAddress: customerAddress,
      reference: reference,
      notes: notes,
      at: at,
    );

    test('a line becomes an order line carrying every snapshot', () {
      final MenuItem pizza = Fixtures.menuItem(
        categoryId: 'cat-test',
        name: 'Test Pizza',
        basePrice: '130.00',
      );
      final MenuItemVariant medium = Fixtures.variant(
        menuItemId: pizza.id,
        name: 'Medium',
        price: '250.00',
      );
      final MenuItemOption extraCheese = Fixtures.option(
        name: 'Extra Cheese',
        price: '70.00',
      );

      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[
          lineOf(
            id: 'l1',
            item: pizza,
            variant: medium,
            options: <MenuItemOption>[extraCheese],
          ),
        ]),
      );

      final OrderItem line = settlement.items.single;
      expect(line.orderId, settlement.orderId);
      expect(line.menuItemId, pizza.id);
      expect(line.variantId, medium.id);
      expect(line.itemNameSnapshot, 'Test Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.quantity, 1);
      expect(line.unitPrice, Money.parse('320'));
      expect(line.totalAmount, Money.parse('320'));

      final OrderItemOption option = settlement.itemOptions.single;
      expect(option.orderItemId, line.id);
      expect(option.optionId, extraCheese.id);
      expect(option.optionNameSnapshot, 'Extra Cheese');
      expect(option.price, Money.parse('70'));
    });

    test('an option row takes the line quantity, so the line reconciles', () {
      // Two pizzas each with extra cheese is two portions of extra cheese, and the
      // rows have to add back up to the line total.
      final MenuItem pizza = itemPriced('250.00');
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[
          lineOf(
            id: 'l1',
            item: pizza,
            options: <MenuItemOption>[
              Fixtures.option(name: 'Extra Cheese', price: '70.00'),
            ],
            quantity: 2,
          ),
        ]),
      );

      final OrderItem line = settlement.items.single;
      final OrderItemOption option = settlement.itemOptions.single;

      expect(option.quantity, 2);
      expect(option.totalAmount, Money.parse('140'));
      expect(line.totalAmount, Money.parse('640'));
      // base 250 x 2, plus the option rows.
      expect(
        Money.parse('250') * line.quantity + option.totalAmount,
        line.totalAmount,
      );
    });

    test('a line with no size carries no variant snapshot', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('70.00'))]),
      );

      final OrderItem line = settlement.items.single;
      expect(line.variantId, isNull);
      expect(line.variantNameSnapshot, isNull);
      expect(line.displayName, 'Test Pizza');
    });

    test('several lines keep their own options apart', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[
          lineOf(
            id: 'l1',
            item: itemPriced('250.00'),
            options: <MenuItemOption>[
              Fixtures.option(name: 'Extra Cheese', price: '70.00'),
            ],
          ),
          lineOf(
            id: 'l2',
            item: itemPriced('70.00'),
            options: <MenuItemOption>[
              Fixtures.option(name: 'Ketchup', price: '10.00'),
            ],
          ),
        ]),
      );

      expect(settlement.items, hasLength(2));
      expect(settlement.itemOptions, hasLength(2));

      final Set<String> lineIds = settlement.items
          .map((OrderItem line) => line.id)
          .toSet();
      expect(lineIds, hasLength(2));
      for (final OrderItemOption option in settlement.itemOptions) {
        expect(lineIds, contains(option.orderItemId));
      }
    });

    test('the payment records exactly the bill total', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[
          lineOf(id: 'l1', item: itemPriced('250.00')),
          lineOf(id: 'l2', item: itemPriced('70.00')),
        ]),
        method: PaymentMethod.upi,
        reference: 'UPI-123',
      );

      expect(settlement.payment.orderId, settlement.orderId);
      expect(settlement.payment.paymentMethod, PaymentMethod.upi);
      expect(settlement.payment.amount, Money.parse('320'));
      expect(settlement.payment.reference, 'UPI-123');
      expect(settlement.payment.status, PaymentStatus.completed);
      expect(settlement.isBalanced, isTrue);
      expect(settlement.amountPayable, Money.parse('320'));
    });

    test('the order header is built once the number is known', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('320.00'))]),
        orderType: OrderType.delivery,
        customerPhone: '9876500001',
        notes: 'No onions',
      );

      expect(settlement.hasCustomer, isTrue);
      expect(settlement.customerPhone, '9876500001');

      // The customer id is supplied by the repository from inside the settlement
      // transaction, which is where the record is resolved or created.
      final Order order = settlement.toOrder(
        '20260911-0007',
        customerId: 'cus-1',
      );

      expect(order.id, settlement.orderId);
      expect(order.orderNumber, '20260911-0007');
      expect(order.orderType, OrderType.delivery);
      expect(order.status, OrderStatus.completed);
      expect(order.customerId, 'cus-1');
      expect(order.customerName, isNull);
      expect(order.notes, 'No onions');
      expect(order.subtotal, Money.parse('320'));
      expect(order.discountAmount, Money.zero);
      expect(order.taxAmount, Money.zero);
      expect(order.totalAmount, Money.parse('320'));
      expect(order.createdAt, at);
      // Consistent with what the payment says was collected.
      expect(order.totalAmount, settlement.payment.amount);
    });

    test('a delivery address is stamped onto the order', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('320.00'))]),
        orderType: OrderType.delivery,
        customerName: 'Ravi',
        customerPhone: '9876500001',
        customerAddress: '12 Baraut Road, Chhaprauli',
      );

      expect(settlement.recordedCustomerAddress, '12 Baraut Road, Chhaprauli');

      final Order order = settlement.toOrder(
        '20260921-0002',
        customerId: 'cus-1',
      );

      expect(order.orderType, OrderType.delivery);
      expect(order.customerName, 'Ravi');
      expect(order.customerAddress, '12 Baraut Road, Chhaprauli');
      expect(order.toMap()['customerAddress'], '12 Baraut Road, Chhaprauli');
    });

    test('a name without a phone is stamped onto the order', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('320.00'))]),
        orderType: OrderType.dineIn,
        customerName: 'Ravi',
      );

      expect(settlement.hasCustomer, isFalse);
      expect(settlement.recordedCustomerName, 'Ravi');

      final Order order = settlement.toOrder('20260921-0001');

      expect(order.customerId, isNull);
      expect(order.customerName, 'Ravi');
      expect(order.orderType, OrderType.dineIn);
    });

    test('every id is fixed when the settlement is built', () {
      // This is what makes a retry safe: the same settlement can only ever write the
      // same rows, so it cannot produce a second bill for one sale.
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('320.00'))]),
      );

      final Order first = settlement.toOrder('20260911-0001');
      final Order second = settlement.toOrder('20260911-0001');

      expect(first.id, second.id);
      expect(settlement.items.single.id, isNotEmpty);
      expect(settlement.payment.id, isNotEmpty);
      expect(settlement.orderId, isNotEmpty);
    });

    test('two settlements of the same cart are different bills', () {
      final Cart cart = cartOf(<CartLine>[
        lineOf(id: 'l1', item: itemPriced('320.00')),
      ]);

      expect(settlementFor(cart).orderId, isNot(settlementFor(cart).orderId));
    });

    test('an empty cart produces a settlement with nothing to write', () {
      final BillSettlement settlement = settlementFor(const Cart.empty());

      expect(settlement.hasLines, isFalse);
      expect(settlement.items, isEmpty);
      expect(settlement.amountPayable, Money.zero);
    });

    test('the line and option lists cannot be modified afterwards', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[
          lineOf(
            id: 'l1',
            item: itemPriced('250.00'),
            options: <MenuItemOption>[
              Fixtures.option(name: 'Extra Cheese', price: '70.00'),
            ],
          ),
        ]),
      );

      expect(
        () => settlement.items.add(settlement.items.single),
        throwsUnsupportedError,
      );
      expect(
        () => settlement.itemOptions.add(settlement.itemOptions.single),
        throwsUnsupportedError,
      );
    });

    test('a payment that disagrees with the total is not balanced', () {
      final BillSettlement settlement = settlementFor(
        cartOf(<CartLine>[lineOf(id: 'l1', item: itemPriced('320.00'))]),
      );

      final BillSettlement tampered = BillSettlement(
        orderId: settlement.orderId,
        orderType: settlement.orderType,
        totals: settlement.totals,
        items: settlement.items,
        itemOptions: settlement.itemOptions,
        payment: settlement.payment.copyWith(amount: Money.parse('300')),
        createdAt: settlement.createdAt,
      );

      expect(tampered.isBalanced, isFalse);
    });
  });
}
