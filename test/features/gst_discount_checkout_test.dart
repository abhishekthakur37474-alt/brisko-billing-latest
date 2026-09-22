import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_discount.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_totals.dart';
import 'package:brisko_billing/features/billing/domain/models/gst_rate.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// A discounted, taxed bill from the counter to the committed row, the paper and the
/// report — and then back out again through a refund.
///
/// ## Why over the real database
///
/// The arithmetic is pinned in `gst_discount_domain_test.dart`. What this file is about is
/// the joins between the parts: that the amount the cashier confirms is the amount that
/// lands in the table, that the paper reads the table rather than the settings, and that a
/// rate change afterwards cannot reach any of it. Those are all claims about the seams, so
/// every repository here is the production one and the cart is built from the real seeded
/// menu.
void main() {
  setUpAll(TestDatabase.register);

  /// The canonical bill: a Medium Cheese Pizza with Extra Cheese, 250 + 70 = 320.
  const String pizzaSubtotal = '320.00';

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkoutRepository;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteRefundRepository refunds;
  late SqliteInventoryDeductionRepository deductions;
  late SqliteSalesReportRepository reports;
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
    refunds = SqliteRefundRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
    reports = SqliteSalesReportRepository(database: database);
    printer = FakeEscPosPrinter();
    printing = TestPrinting.serviceOver(database, printer: printer);
    billing = await SeededCart.controller(menu);
  });

  tearDown(() async {
    billing.dispose();
    await database.close();
  });

  Future<void> ringUpPizza({int quantity = 1}) => SeededCart.add(
    billing,
    category: 'SIMPLY VEG',
    item: 'Cheese Pizza',
    size: 'Medium',
    options: <String>['Extra Cheese'],
    quantity: quantity,
  );

  /// A checkout over the live cart, at [taxRate].
  CheckoutController openCheckout({GstRate taxRate = GstRate.zero}) {
    final CheckoutController controller = CheckoutController(
      cart: billing.cart,
      checkoutRepository: checkoutRepository,
      customerRepository: customers,
      inventoryDeductionRepository: deductions,
      printService: printing,
      onSettled: billing.clearCart,
      taxRate: taxRate,
    );
    addTearDown(controller.dispose);
    controller.setCustomerName('Test Customer');
    controller.setCustomerPhone('9000000001');
    return controller;
  }

  /// Settles the live cart at [taxRate] with [discount], paying the exact amount in cash.
  ///
  /// Returns the controller so a test can read what the cashier was shown, and assert it
  /// against what was written.
  Future<CheckoutController> settle({
    GstRate taxRate = GstRate.zero,
    String? percentage,
    String? amount,
  }) async {
    final CheckoutController controller = openCheckout(taxRate: taxRate);

    if (percentage != null || amount != null) {
      controller.setDiscountOpen(isOpen: true);
      if (amount != null) {
        controller.selectDiscountType(BillDiscountType.amount);
        controller.editDiscount(amount);
      } else {
        controller.editDiscount(percentage!);
      }
    }

    controller.goToPayment();
    controller.selectPaymentMethod(PaymentMethod.cash);
    controller.tenderExact();
    controller.goToConfirm();
    await controller.submit();

    expect(
      controller.hasError,
      isFalse,
      reason: controller.errorMessage ?? 'settlement failed',
    );
    return controller;
  }

  /// The receipt for the most recent print run.
  EscPosTranscript receipt() => EscPosTranscript.of(
    printer.jobs
        .lastWhere((PrintJob job) => job.kind == PrintJobKind.customerReceipt)
        .bytes,
  );

  // ----------------------------------------------------------------- persistence ---

  group('what a settled bill keeps', () {
    test('a plain untaxed bill is written exactly as it always was', () async {
      // The regression that matters most: an outlet that has configured nothing must settle
      // the same bill it settled before this step existed.
      await ringUpPizza();
      final CheckoutController controller = await settle();
      final Order order = controller.settledOrder!;

      expect(order.subtotal, Money.parse(pizzaSubtotal));
      expect(order.discountAmount, Money.zero);
      expect(order.taxAmount, Money.zero);
      expect(order.totalAmount, Money.parse(pizzaSubtotal));
      expect(order.taxRateBasisPoints, 0);
      expect(order.discountType, isNull);
      expect(order.discountValue, 0);
    });

    test('the rate and the rule are stored with the bill', () async {
      // 320 less 10% is 288, GST 18% of 288 is 51.84, total 339.84.
      await ringUpPizza();
      final CheckoutController controller = await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      );
      final Order order = controller.settledOrder!;

      expect(order.subtotal, Money.parse('320.00'));
      expect(order.discountAmount, Money.parse('32.00'));
      expect(order.taxableAmount, Money.parse('288.00'));
      expect(order.taxAmount, Money.parse('51.84'));
      expect(order.totalAmount, Money.parse('339.84'));
      // The rate in force, copied onto the bill.
      expect(order.taxRateBasisPoints, 1800);
      // And the rule that produced the discount, so `10%` survives rather than only `32.00`.
      expect(order.discountType, 'percentage');
      expect(order.discountValue, 1000);
    });

    test('a fixed discount stores its rule in paise', () async {
      await ringUpPizza();
      final CheckoutController controller = await settle(
        taxRate: const GstRate.ofBasisPoints(500),
        amount: '20',
      );
      final Order order = controller.settledOrder!;

      expect(order.discountAmount, Money.parse('20.00'));
      expect(order.discountType, 'amount');
      expect(order.discountValue, 2000);
      // 300 taxable at 5% is 15.00.
      expect(order.taxAmount, Money.parse('15.00'));
      expect(order.totalAmount, Money.parse('315.00'));
    });

    test('the figures come back off disk unchanged', () async {
      await ringUpPizza();
      final CheckoutController controller = await settle(
        taxRate: const GstRate.ofBasisPoints(1200),
        percentage: '5',
      );
      final Order written = controller.settledOrder!;

      final Order reread = (await orders.findOrder(written.id)).valueOrNull!;

      expect(reread.subtotal, written.subtotal);
      expect(reread.discountAmount, written.discountAmount);
      expect(reread.taxAmount, written.taxAmount);
      expect(reread.totalAmount, written.totalAmount);
      expect(reread.taxRateBasisPoints, written.taxRateBasisPoints);
      expect(reread.discountType, written.discountType);
      expect(reread.discountValue, written.discountValue);
    });

    test('the stored columns are integers, and the rate is not a paise column', () async {
      await ringUpPizza();
      final CheckoutController controller = await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      );

      final Map<String, Object?> row = (await database.database.query(
        SqliteTables.orders,
        where: 'id = ?',
        whereArgs: <Object?>[controller.settledOrder!.id],
      )).single;

      // Every amount and the rate arrive as `int`. Not a double, and not text.
      for (final String column in <String>[
        'subtotalPaise',
        'discountAmountPaise',
        'taxAmountPaise',
        'totalAmountPaise',
        'taxRateBasisPoints',
        'discountValue',
      ]) {
        expect(row[column], isA<int>(), reason: '$column must be an integer');
      }
      expect(row['taxRateBasisPoints'], 1800);
      // The rule's magnitude is deliberately not named as an amount: for a percentage it is
      // not money at all.
      expect(row.containsKey('discountValuePaise'), isFalse);
    });

    test('changing the GST rate afterwards does not touch a settled bill', () async {
      // The single most important guarantee in this step.
      await ringUpPizza();
      final CheckoutController first = await settle(
        taxRate: const GstRate.ofBasisPoints(500),
      );
      final Order atFivePercent = first.settledOrder!;

      // 320 at 5% is 16.00, total 336.00.
      expect(atFivePercent.taxAmount, Money.parse('16.00'));
      expect(atFivePercent.totalAmount, Money.parse('336.00'));

      // The outlet moves to 18% and takes another bill.
      await ringUpPizza();
      final CheckoutController second = await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
      );

      expect(second.settledOrder!.taxAmount, Money.parse('57.60'));
      expect(second.settledOrder!.totalAmount, Money.parse('377.60'));

      // And the first bill is exactly as it was. Not restated at the new rate.
      final Order reread = (await orders.findOrder(atFivePercent.id))
          .valueOrNull!;
      expect(reread.taxRateBasisPoints, 500);
      expect(reread.taxAmount, Money.parse('16.00'));
      expect(reread.totalAmount, Money.parse('336.00'));
    });
  });

  // -------------------------------------------------------------------- checkout ---

  group('checkout charges what it showed', () {
    test('the payable amount is the calculated total at every step', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(
        taxRate: const GstRate.ofBasisPoints(1800),
      );

      // 320 at 18% is 57.60, total 377.60.
      expect(controller.totals.total, Money.parse('377.60'));
      expect(controller.amountPayable, controller.totals.total);

      controller.setDiscountOpen(isOpen: true);
      controller.editDiscount('10');

      // 288 taxable, 51.84 tax, 339.84 total.
      expect(controller.totals.total, Money.parse('339.84'));
      expect(controller.amountPayable, Money.parse('339.84'));

      controller.goToPayment();
      expect(controller.amountPayable, Money.parse('339.84'));
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.tenderExact();
      controller.goToConfirm();
      expect(controller.amountPayable, Money.parse('339.84'));
    });

    test(
      'the persisted total, the tender and the shown total all agree',
      () async {
        await ringUpPizza(quantity: 3);
        final CheckoutController controller = await settle(
          taxRate: const GstRate.ofBasisPoints(1800),
          percentage: '12.5',
        );

        final BillTotals shown = controller.totals;
        final Order order = controller.settledOrder!;
        final Payment tender = (await payments.loadForOrder(order.id))
            .valueOrNull!
            .single;

        expect(order.totalAmount, shown.total);
        expect(order.subtotal, shown.subtotal);
        expect(order.discountAmount, shown.discount);
        expect(order.taxAmount, shown.tax);
        // The tender recorded against the bill is the bill.
        expect(tender.amount, shown.total);
        // And the block still adds up on disk.
        expect(
          order.subtotal - order.discountAmount + order.taxAmount,
          order.totalAmount,
        );
      },
    );

    test('applying a discount resets the cash already counted', () async {
      // Otherwise ₹340 counted against a ₹377.60 bill would still read as sufficient after
      // the discount was removed, and the cashier would be told the customer had paid.
      await ringUpPizza();
      final CheckoutController controller = openCheckout(
        taxRate: const GstRate.ofBasisPoints(1800),
      );

      controller.goToPayment();
      controller.selectPaymentMethod(PaymentMethod.cash);
      controller.tenderExact();
      expect(controller.isTenderSufficient, isTrue);

      controller.setDiscountOpen(isOpen: true);
      controller.editDiscount('10');

      expect(controller.cashTender.tendered, Money.zero);
      expect(controller.isTenderSufficient, isFalse);
      expect(controller.cashTender.payable, Money.parse('339.84'));
      expect(controller.canProceedToConfirm, isFalse);
    });

    test('a discount that cannot be read blocks the step', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.setDiscountOpen(isOpen: true);

      controller.editDiscount('abc');

      expect(controller.discountProblem, isNotNull);
      expect(controller.canProceedToPayment, isFalse);
      // And nothing was applied, so no amount was quietly changed.
      expect(controller.totals.discount, Money.zero);
      expect(controller.totals.total, Money.parse(pizzaSubtotal));

      // Correcting it clears the block.
      controller.editDiscount('10');
      expect(controller.discountProblem, isNull);
      expect(controller.canProceedToPayment, isTrue);
      expect(controller.totals.discount, Money.parse('32.00'));
    });

    test('a discount larger than the bill is refused with a reason', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.setDiscountOpen(isOpen: true);
      controller.selectDiscountType(BillDiscountType.amount);

      controller.editDiscount('500');

      expect(controller.discountProblem, contains('320.00'));
      expect(controller.canProceedToPayment, isFalse);
      expect(controller.totals.total, Money.parse(pizzaSubtotal));
    });

    test('closing the discount control removes the discount', () async {
      // A reduction with nothing on screen explaining it is the one state this must not be
      // in.
      await ringUpPizza();
      final CheckoutController controller = openCheckout();
      controller.setDiscountOpen(isOpen: true);
      controller.editDiscount('10');
      expect(controller.totals.discount, Money.parse('32.00'));

      controller.setDiscountOpen(isOpen: false);

      expect(controller.totals.discount, Money.zero);
      expect(controller.totals.total, Money.parse(pizzaSubtotal));
      expect(controller.discountEntry, isEmpty);
    });

    test(
      'switching the rule clears the value rather than reinterpreting it',
      () async {
        // `10` means ten percent under one rule and ten rupees under the other.
        await ringUpPizza();
        final CheckoutController controller = openCheckout();
        controller.setDiscountOpen(isOpen: true);
        controller.editDiscount('10');
        expect(controller.totals.discount, Money.parse('32.00'));

        controller.selectDiscountType(BillDiscountType.amount);

        expect(controller.discountEntry, isEmpty);
        expect(controller.totals.discount, Money.zero);
      },
    );

    test('a 100% discount leaves nothing to settle', () async {
      await ringUpPizza();
      final CheckoutController controller = openCheckout(
        taxRate: const GstRate.ofBasisPoints(1800),
      );
      controller.setDiscountOpen(isOpen: true);
      controller.editDiscount('100');

      expect(controller.totals.total, Money.zero);
      // The existing rule that an unpayable bill cannot be settled still holds, so a fully
      // discounted bill cannot be charged.
      expect(controller.hasBill, isFalse);
      expect(controller.canProceedToPayment, isFalse);
    });

    test('the settlement refuses a bill that would go negative', () async {
      // The guard at the storage boundary. Nothing the UI can do reaches it — the discount
      // is clamped and refused long before here — so it is reached by building a settlement
      // by hand, which is what a future caller could do. Once a row is committed it is the
      // historical record, so this is the last moment a wrong figure can be stopped.
      await ringUpPizza();
      final BillSettlement sound = BillSettlement.fromCart(
        cart: billing.cart,
        orderType: OrderType.takeaway,
        paymentMethod: PaymentMethod.cash,
        taxRate: const GstRate.ofBasisPoints(1800),
      );

      expect(sound.isArithmeticSound, isTrue);
      expect(sound.isBalanced, isTrue);

      // A discount larger than the subtotal, which the const constructor will hold even
      // though `BillTotals.of` clamps it away.
      final BillSettlement broken = BillSettlement(
        orderId: sound.orderId,
        orderType: sound.orderType,
        totals: const BillTotals(
          subtotal: Money.fromPaise(32000),
          discount: Money.fromPaise(40000),
        ),
        payment: sound.payment,
        createdAt: sound.createdAt,
        items: sound.items,
        itemOptions: sound.itemOptions,
      );

      expect(broken.totals.total.isNegative, isTrue);
      expect(broken.isArithmeticSound, isFalse);

      final String? failure = (await checkoutRepository.settle(broken))
          .failureOrNull
          ?.message;
      expect(failure, isNotNull);
      expect(failure, contains('does not add up'));

      // And nothing was written.
      final List<Map<String, Object?>> rows = await database.database.query(
        SqliteTables.orders,
      );
      expect(rows, isEmpty);
    });
  });

  // --------------------------------------------------------------------- receipt ---

  group('the receipt prints the persisted bill', () {
    test('a discounted taxed bill prints every line and adds up', () async {
      await ringUpPizza();
      await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      );

      final EscPosTranscript paper = receipt();

      expect(paper.lineContaining('Subtotal')!.endsWith('320.00'), isTrue);
      expect(paper.lineContaining('Discount')!.endsWith('-32.00'), isTrue);
      expect(paper.lineContaining('Discount')!, contains('10%'));
      expect(
        paper.lineContaining('Taxable amount')!.endsWith('288.00'),
        isTrue,
      );
      // 51.84 halves to 25.92 each.
      expect(paper.lineContaining('CGST 9%')!.endsWith('25.92'), isTrue);
      expect(paper.lineContaining('SGST 9%')!.endsWith('25.92'), isTrue);
      expect(paper.lineContaining('TOTAL')!.endsWith('339.84'), isTrue);
      expect(paper.widestLine, lessThanOrEqualTo(48));
    });

    test('an untaxed undiscounted bill prints neither line', () async {
      await ringUpPizza();
      await settle();

      final EscPosTranscript paper = receipt();

      expect(paper.hasLineContaining('Discount'), isFalse);
      expect(paper.hasLineContaining('CGST'), isFalse);
      expect(paper.hasLineContaining('SGST'), isFalse);
      expect(paper.hasLineContaining('Taxable'), isFalse);
      expect(paper.lineContaining('TOTAL')!.endsWith('320.00'), isTrue);
    });

    test(
      'a reprint after the rate changes prints the original figures',
      () async {
        await ringUpPizza();
        final CheckoutController controller = await settle(
          taxRate: const GstRate.ofBasisPoints(500),
        );
        final String orderId = controller.settledOrder!.id;
        final String originalTotal = receipt()
            .lineContaining('TOTAL INR')!
            .trim();

        // 320 at 5% is 16.00, total 336.00.
        expect(originalTotal.endsWith('336.00'), isTrue);
        expect(receipt().lineContaining('CGST 2.5%')!.endsWith('8.00'), isTrue);

        // The outlet moves to 18% and the bill is reprinted.
        printer.clearRecording();
        await printing.reprintReceipt(orderId);

        final EscPosTranscript reprint = receipt();
        expect(reprint.lineContaining('TOTAL INR')!.trim(), originalTotal);
        expect(reprint.lineContaining('CGST 2.5%')!.endsWith('8.00'), isTrue);
        expect(reprint.hasLineContaining('CGST 9%'), isFalse);
      },
    );

    test('the kitchen slip still carries none of it', () async {
      await ringUpPizza();
      await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      );

      final EscPosTranscript slip = EscPosTranscript.of(
        printer.jobs
            .lastWhere((PrintJob job) => job.kind == PrintJobKind.kitchenKot)
            .bytes,
      );

      for (final String forbidden in <String>[
        'Subtotal',
        'Discount',
        'Taxable',
        'GST',
        'CGST',
        'SGST',
        'TOTAL',
        'Paid',
        'INR',
      ]) {
        expect(
          slip.hasLineContaining(forbidden),
          isFalse,
          reason: 'the kitchen slip must not mention $forbidden',
        );
      }
      // And no amount of any kind.
      expect(RegExp(r'\d+\.\d{2}').hasMatch(slip.text), isFalse);
      expect(slip.hasLineContaining('Cheese Pizza'), isTrue);
    });
  });

  // --------------------------------------------------------------------- reports ---

  group('reports total what was charged', () {
    test(
      'a range spanning a rate change totals each bill at its own rate',
      () async {
        await ringUpPizza();
        await settle(taxRate: const GstRate.ofBasisPoints(500));
        await ringUpPizza();
        await settle(
          taxRate: const GstRate.ofBasisPoints(1800),
          percentage: '10',
        );

        final SalesSummary summary = (await reports.loadSummary(
          DateRange.day(DateTime.now()),
        )).valueOrNull!;

        expect(summary.billCount, 2);
        // Subtotals: 320 + 320.
        expect(summary.subtotal, Money.parse('640.00'));
        // Discounts: 0 + 32.
        expect(summary.discountTotal, Money.parse('32.00'));
        expect(summary.taxableSales, Money.parse('608.00'));
        // Tax: 16.00 at 5% plus 51.84 at 18%. Each at the rate its own bill carried.
        expect(summary.taxTotal, Money.parse('67.84'));
        expect(summary.grossSales, Money.parse('675.84'));
        // And the tax reconciles: taxable plus tax is the gross.
        expect(summary.taxableSales + summary.taxTotal, summary.grossSales);
        // The halves add back to the whole, so the split cannot double count.
        expect(summary.cgstTotal + summary.sgstTotal, summary.taxTotal);
      },
    );

    test(
      'a refund nets against the taxed gross without disturbing it',
      () async {
        await ringUpPizza();
        final CheckoutController controller = await settle(
          taxRate: const GstRate.ofBasisPoints(1800),
        );
        final String orderId = controller.settledOrder!.id;
        final DateRange today = DateRange.day(DateTime.now());

        final RefundableBill bill = (await refunds.loadRefundable(orderId))
            .valueOrNull!;
        await refunds.refund(RefundRequest.forBill(bill));

        final SalesSummary summary = (await reports.loadSummary(today))
            .valueOrNull!;

        // The bill stays counted at what it was rung up for, tax included.
        expect(summary.billCount, 1);
        expect(summary.grossSales, Money.parse('377.60'));
        expect(summary.taxTotal, Money.parse('57.60'));
        // And the whole of it, tax included, is netted off.
        expect(summary.refundTotal, Money.parse('377.60'));
        expect(summary.netSales, Money.zero);
      },
    );
  });

  // ------------------------------------------------------- refund and cancellation ---

  group('a reversal reads the bill, not the settings', () {
    test('a refund returns the taxed total the customer paid', () async {
      await ringUpPizza();
      final CheckoutController controller = await settle(
        taxRate: const GstRate.ofBasisPoints(500),
        percentage: '10',
      );
      final Order order = controller.settledOrder!;

      // 320 less 32 is 288, at 5% that is 14.40, total 302.40.
      expect(order.totalAmount, Money.parse('302.40'));

      final RefundableBill bill = (await refunds.loadRefundable(order.id))
          .valueOrNull!;

      expect(bill.paidAmount, Money.parse('302.40'));
      expect(bill.refundableAmount, Money.parse('302.40'));

      final Refund written = (await refunds.refund(RefundRequest.forBill(bill)))
          .valueOrNull!;

      // The whole of what was collected, tax and all, and not a paisa recalculated.
      expect(written.amount, order.totalAmount);
    });

    test(
      'a refund after the rate changes still uses the original bill',
      () async {
        // The example from the requirement: a bill taken at 5%, refunded after the outlet
        // moved to 18%.
        await ringUpPizza();
        final Order old = (await settle(
          taxRate: const GstRate.ofBasisPoints(500),
        )).settledOrder!;
        expect(old.totalAmount, Money.parse('336.00'));

        // A later bill at the new rate, so the terminal is demonstrably on 18% now.
        await ringUpPizza();
        final Order recent = (await settle(
          taxRate: const GstRate.ofBasisPoints(1800),
        )).settledOrder!;
        expect(recent.totalAmount, Money.parse('377.60'));

        final Refund written = (await refunds.refund(
          RefundRequest.forBill(
            (await refunds.loadRefundable(old.id)).valueOrNull!,
          ),
        )).valueOrNull!;

        // The old bill's own total, not today's rate applied to its subtotal.
        expect(written.amount, Money.parse('336.00'));
        expect(written.amount, isNot(Money.parse('377.60')));

        // And the refunded bill is untouched: same rate, same tax, same total.
        final Order reread = (await orders.findOrder(old.id)).valueOrNull!;
        expect(reread.taxRateBasisPoints, 500);
        expect(reread.taxAmount, Money.parse('16.00'));
        expect(reread.totalAmount, Money.parse('336.00'));
        expect(reread.status, OrderStatus.completed);
      },
    );

    test('refunding twice is still refused, on a taxed bill too', () async {
      await ringUpPizza();
      final Order order = (await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      )).settledOrder!;

      final RefundRequest request = RefundRequest.forBill(
        (await refunds.loadRefundable(order.id)).valueOrNull!,
      );
      expect((await refunds.refund(request)).isOk, isTrue);

      // The second attempt is refused rather than handing the money back twice.
      final RefundableBill after = (await refunds.loadRefundable(order.id))
          .valueOrNull!;
      expect(after.canRefund, isFalse);
      expect(after.refundedAmount, order.totalAmount);
      expect(after.refundableAmount, Money.zero);
    });

    test('cancelling recalculates nothing', () async {
      await ringUpPizza();
      final Order before = (await settle(
        taxRate: const GstRate.ofBasisPoints(1200),
        amount: '20',
      )).settledOrder!;

      final Order after = (await orders.cancelOrder(before.id)).valueOrNull!;

      // The status moved, and that is the whole of it.
      expect(after.status, OrderStatus.cancelled);
      expect(after.subtotal, before.subtotal);
      expect(after.discountAmount, before.discountAmount);
      expect(after.taxAmount, before.taxAmount);
      expect(after.totalAmount, before.totalAmount);
      expect(after.taxRateBasisPoints, before.taxRateBasisPoints);
      expect(after.discountType, before.discountType);
      expect(after.discountValue, before.discountValue);
      // Compared at the precision the column holds. `before` is the in-memory order, which
      // carries microseconds; the row stores epoch milliseconds. Equal milliseconds is what
      // "createdAt was not rewritten" means for a persisted bill.
      expect(
        after.createdAt.millisecondsSinceEpoch,
        before.createdAt.millisecondsSinceEpoch,
      );
    });

    test('a cancelled taxed bill drops out of the takings entirely', () async {
      await ringUpPizza();
      final Order order = (await settle(
        taxRate: const GstRate.ofBasisPoints(1800),
        percentage: '10',
      )).settledOrder!;

      await orders.cancelOrder(order.id);

      final SalesSummary summary = (await reports.loadSummary(
        DateRange.day(DateTime.now()),
      )).valueOrNull!;

      // Including its tax and its discount. A cancelled bill contributes nothing anywhere.
      expect(summary.billCount, 0);
      expect(summary.subtotal, Money.zero);
      expect(summary.discountTotal, Money.zero);
      expect(summary.taxTotal, Money.zero);
      expect(summary.grossSales, Money.zero);
    });
  });
}
