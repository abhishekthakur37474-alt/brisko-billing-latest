import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_summary.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/item_sales_row.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_bill.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// What a refund does, and does not do, to the figures.
///
/// ## The two things this file is protecting
///
/// Gross sales must stay exactly what the day's receipts add up to, because that is the
/// figure an auditor reconciles. And a refund must never be counted as a second sale, in any
/// of the four reports.
///
/// Everything else follows from those two: net is gross minus the reversals, and the payment
/// mix nets the same way over the same rows so the two sides agree.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteRefundRepository refunds;
  late SqliteSalesReportRepository reports;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqliteMenuRepository menu;

  final DateTime billedAt = DateTime(2026, 4, 9, 13, 30);
  final DateTime refundedAt = DateTime(2026, 4, 9, 15, 5);
  final DateRange thatDay = DateRange.day(DateTime(2026, 4, 9));
  final DateRange nextDay = DateRange.day(DateTime(2026, 4, 10));

  setUp(() async {
    database = await TestDatabase.openInMemory();
    seed = SeededSales(database);
    refunds = SqliteRefundRepository(database: database);
    reports = SqliteSalesReportRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    menu = SqliteMenuRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  Future<String> settledBill({
    String orderNumber = '20260409-0001',
    String? customerId,
    String? kotNumber = 'K20260409-0001',
    PaymentMethod? paymentMethod = PaymentMethod.cash,
    DateTime? at,
    List<BillLineSpec> lines = const <BillLineSpec>[BillLineSpec()],
  }) {
    return seed.bill(
      orderNumber: orderNumber,
      at: at ?? billedAt,
      customerId: customerId,
      kotNumber: kotNumber,
      paymentMethod: paymentMethod,
      lines: lines,
    );
  }

  Future<Result<Refund>> refundWholeBill(String orderId, {DateTime? at}) async {
    final RefundableBill bill = (await refunds.loadRefundable(orderId))
        .valueOrNull!;
    return refunds.refund(RefundRequest.forBill(bill, at: at ?? refundedAt));
  }

  Future<SalesSummary> summaryOf(DateRange range) async =>
      (await reports.loadSummary(range)).valueOrNull!;

  Future<PaymentMix> mixOf(DateRange range) async =>
      (await reports.loadPaymentMix(range)).valueOrNull!;

  group('gross sales stay auditable', () {
    test('a refunded bill still counts as a settled sale', () async {
      final String id = await settledBill();
      final SalesSummary before = await summaryOf(thatDay);
      expect(before.billCount, 1);
      expect(before.grossSales.paise, 21000);

      await refundWholeBill(id);

      final SalesSummary after = await summaryOf(thatDay);
      // The sale happened and the customer holds a receipt for it. Gross does not move.
      expect(after.billCount, 1);
      expect(after.grossSales.paise, 21000);
      expect(after.subtotal.paise, 20000);
      expect(after.taxTotal.paise, 1000);
      expect(after.itemCount, 2);
    });

    test('the refund is reported beside the gross, not inside it', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      final SalesSummary after = await summaryOf(thatDay);
      expect(after.hasRefunds, isTrue);
      expect(after.refundTotal.paise, 21000);
      expect(after.netSales.paise, 0);
      // And the gross is still readable as the sum of its parts.
      expect(
        after.subtotal.paise + after.taxTotal.paise,
        after.grossSales.paise,
      );
    });

    test('a day with no refunds reports zero rather than nothing', () async {
      await settledBill();

      final SalesSummary summary = await summaryOf(thatDay);

      expect(summary.hasRefunds, isFalse);
      expect(summary.refundTotal.paise, 0);
      // Net equals gross when nothing went back, which is what makes the two figures safe to
      // show side by side.
      expect(summary.netSales.paise, summary.grossSales.paise);
    });

    test('an empty range reports zero refunds', () async {
      final SalesSummary summary = await summaryOf(nextDay);

      expect(summary.isEmpty, isTrue);
      expect(summary.refundTotal.paise, 0);
      expect(summary.netSales.paise, 0);
    });

    test('a bill refunded and a bill not refunded net correctly', () async {
      final String refunded = await settledBill();
      await settledBill(
        orderNumber: '20260409-0009',
        kotNumber: 'K20260409-0009',
      );

      await refundWholeBill(refunded);

      final SalesSummary summary = await summaryOf(thatDay);
      expect(summary.billCount, 2);
      expect(summary.grossSales.paise, 42000);
      expect(summary.refundTotal.paise, 21000);
      expect(summary.netSales.paise, 21000);
    });
  });

  group('a refund is never a second sale', () {
    test('the bill count does not rise', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      expect((await summaryOf(thatDay)).billCount, 1);
    });

    test('the bills list still holds one row, marked refunded', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      final List<SalesBill> bills = (await reports.loadBills(thatDay))
          .valueOrNull!;
      expect(bills, hasLength(1));
      final SalesBill listed = bills.single;
      expect(listed.orderNumber, '20260409-0001');
      // Full total, because that is what was rung up.
      expect(listed.total.paise, 21000);
      expect(listed.isRefunded, isTrue);
      expect(listed.refundedAmount.paise, 21000);
      expect(listed.netTotal.paise, 0);
    });

    test('an unrefunded bill in the list reports no reversal', () async {
      await settledBill();

      final SalesBill listed = (await reports.loadBills(thatDay))
          .valueOrNull!
          .single;

      expect(listed.isRefunded, isFalse);
      expect(listed.refundedAmount.paise, 0);
      expect(listed.netTotal.paise, 21000);
    });

    test('item sales are untouched: nothing was un-sold', () async {
      final String id = await settledBill();
      final List<ItemSalesRow> before = (await reports.loadItemSales(thatDay))
          .valueOrNull!;
      expect(before, hasLength(1));

      await refundWholeBill(id);

      final List<ItemSalesRow> after = (await reports.loadItemSales(thatDay))
          .valueOrNull!;
      // The dish was made and left the kitchen. Item sales record what was sold, and a
      // reversal of money is not a reversal of that.
      expect(after, hasLength(1));
      expect(after.single.quantitySold, before.single.quantitySold);
      expect(after.single.salesAmount.paise, before.single.salesAmount.paise);
    });

    test('the item report gains no refund row of its own', () async {
      final String id = await settledBill();

      await refundWholeBill(id);

      final List<ItemSalesRow> rows = (await reports.loadItemSales(thatDay))
          .valueOrNull!;
      expect(rows, hasLength(1));
      expect(
        rows.map((ItemSalesRow row) => row.itemName),
        isNot(contains('Refund')),
      );
    });
  });

  group('the payment mix reconciles', () {
    test('takings stay, and the reversal appears beside them', () async {
      final String id = await settledBill();
      final PaymentMix before = await mixOf(thatDay);
      expect(before.amountFor(PaymentMethod.cash).paise, 21000);
      expect(before.hasRefunds, isFalse);

      await refundWholeBill(id);

      final PaymentMix after = await mixOf(thatDay);
      // The tender still says money arrived.
      expect(after.amountFor(PaymentMethod.cash).paise, 21000);
      expect(after.countFor(PaymentMethod.cash), 1);
      // And the reversal says some of it went back.
      expect(after.refundedFor(PaymentMethod.cash).paise, 21000);
      expect(after.refundCountFor(PaymentMethod.cash), 1);
      expect(after.netFor(PaymentMethod.cash).paise, 0);
      expect(after.hasRefunds, isTrue);
    });

    test('completed payments minus completed refunds is the net', () async {
      final String refunded = await settledBill();
      await settledBill(
        orderNumber: '20260409-0009',
        kotNumber: 'K20260409-0009',
      );

      await refundWholeBill(refunded);

      final PaymentMix mix = await mixOf(thatDay);
      expect(mix.total.paise, 42000);
      expect(mix.refundTotal.paise, 21000);
      expect(mix.netTotal.paise, 21000);
      expect(mix.total.paise - mix.refundTotal.paise, mix.netTotal.paise);
    });

    test('the mix nets to exactly the summary net', () async {
      final String refunded = await settledBill();
      await settledBill(
        orderNumber: '20260409-0009',
        kotNumber: 'K20260409-0009',
        paymentMethod: PaymentMethod.upi,
      );
      await settledBill(
        orderNumber: '20260409-0010',
        kotNumber: 'K20260409-0010',
        paymentMethod: PaymentMethod.card,
      );

      await refundWholeBill(refunded);

      final SalesSummary summary = await summaryOf(thatDay);
      final PaymentMix mix = await mixOf(thatDay);

      // The reconciliation the summary screen renders a warning about. Both sides come out
      // of the same statement over the same rows, so equality here is a real guarantee.
      expect(mix.netTotal.paise, summary.netSales.paise);
      expect(mix.total.paise, summary.grossSales.paise);
      expect(mix.refundTotal.paise, summary.refundTotal.paise);
    });

    test('a refund goes back under the method it came in on', () async {
      final String id = await settledBill(paymentMethod: PaymentMethod.upi);

      await refundWholeBill(id);

      final PaymentMix mix = await mixOf(thatDay);
      expect(mix.refundedFor(PaymentMethod.upi).paise, 21000);
      // And nowhere else.
      for (final PaymentMethod method in PaymentMethod.values) {
        if (method == PaymentMethod.upi) {
          continue;
        }
        expect(mix.refundedFor(method).paise, 0);
        expect(mix.refundCountFor(method), 0);
      }
    });

    test('every method answers for refunds, even ones with none', () async {
      final String id = await settledBill();
      await refundWholeBill(id);

      final PaymentMix mix = await mixOf(thatDay);

      // A missing bucket reads as a report that forgot a method. All four always answer.
      for (final PaymentMethod method in PaymentMethod.values) {
        expect(mix.refundedFor(method), isNotNull);
        expect(mix.refundCountFor(method), isNotNull);
      }
      expect(PaymentMix.methods, PaymentMethod.values);
    });

    test('a refund on a method with no takings still appears', () async {
      // Money in on cash, and a card bill refunded, so the card row carries a reversal
      // against zero takings of its own on that method.
      final String card = await settledBill(paymentMethod: PaymentMethod.card);
      await settledBill(
        orderNumber: '20260409-0009',
        kotNumber: 'K20260409-0009',
      );

      await refundWholeBill(card);

      final PaymentMix mix = await mixOf(thatDay);
      expect(mix.amountFor(PaymentMethod.card).paise, 21000);
      expect(mix.refundedFor(PaymentMethod.card).paise, 21000);
      expect(mix.netFor(PaymentMethod.card).paise, 0);
      expect(mix.netFor(PaymentMethod.cash).paise, 21000);
    });

    test('an empty mix reports no refunds', () async {
      final PaymentMix mix = await mixOf(nextDay);

      expect(mix.isEmpty, isTrue);
      expect(mix.hasRefunds, isFalse);
      expect(mix.refundTotal.paise, 0);
      expect(mix.netTotal.paise, 0);
    });

    test(
      'a range whose takings were all refunded is not called empty',
      () async {
        final String id = await settledBill();
        await refundWholeBill(id);

        final PaymentMix mix = await mixOf(thatDay);

        // Money moved through it twice. Calling that empty would hide both movements.
        expect(mix.isEmpty, isFalse);
        expect(mix.tenderCount, 1);
        expect(mix.refundCount, 1);
        expect(mix.netTotal.paise, 0);
      },
    );
  });

  group('a refund belongs to the day of the bill it reverses', () {
    test('money handed back later reduces that earlier day', () async {
      final String id = await settledBill();

      // Refunded the following day.
      await refundWholeBill(id, at: DateTime(2026, 4, 10, 11));

      final SalesSummary day = await summaryOf(thatDay);
      expect(day.grossSales.paise, 21000);
      expect(day.refundTotal.paise, 21000);
      expect(day.netSales.paise, 0);

      // And the day the money physically left has no sale and no refund of its own, so the
      // payment mix for that day cannot disagree with its sales.
      final SalesSummary later = await summaryOf(nextDay);
      expect(later.billCount, 0);
      expect(later.refundTotal.paise, 0);

      final PaymentMix laterMix = await mixOf(nextDay);
      expect(laterMix.refundTotal.paise, 0);
      expect(laterMix.netTotal.paise, laterMix.total.paise);
    });

    test('a refund does not leak into a range the bill is outside', () async {
      final String earlier = await settledBill(at: DateTime(2026, 4, 8, 12));

      await refundWholeBill(earlier, at: refundedAt);

      expect((await summaryOf(thatDay)).refundTotal.paise, 0);
      expect((await mixOf(thatDay)).refundTotal.paise, 0);
    });
  });

  group('the customer', () {
    test('their visit still counts and their net spend drops', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      final CustomerSummary before = (await customers.loadSummary(customerId))
          .valueOrNull!;
      expect(before.completedOrderCount, 1);
      expect(before.totalSpent.paise, 21000);
      expect(before.netSpent.paise, 21000);
      expect(before.hasRefunds, isFalse);

      await refundWholeBill(id);

      final CustomerSummary after = (await customers.loadSummary(customerId))
          .valueOrNull!;
      // The visit happened. Dropping the count would make them look like someone who had
      // never come in.
      expect(after.completedOrderCount, 1);
      expect(after.totalSpent.paise, 21000);
      // What they actually paid.
      expect(after.refundedTotal.paise, 21000);
      expect(after.netSpent.paise, 0);
      expect(after.hasRefunds, isTrue);
    });

    test('the directory agrees with the summary', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await refundWholeBill(id);

      final CustomerSummary listed =
          (await customers.loadDirectory()).valueOrNull!.single;
      expect(listed.customer.id, customerId);
      expect(listed.completedOrderCount, 1);
      expect(listed.totalSpent.paise, 21000);
      expect(listed.refundedTotal.paise, 21000);
      expect(listed.netSpent.paise, 0);
    });

    test('their other bill is unaffected', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String refunded = await settledBill(customerId: customerId);
      await settledBill(
        orderNumber: '20260409-0008',
        kotNumber: 'K20260409-0008',
        customerId: customerId,
      );

      await refundWholeBill(refunded);

      final CustomerSummary after = (await customers.loadSummary(customerId))
          .valueOrNull!;
      expect(after.completedOrderCount, 2);
      expect(after.totalSpent.paise, 42000);
      expect(after.refundedTotal.paise, 21000);
      expect(after.netSpent.paise, 21000);
    });

    test('the average order value follows the net, not the billed', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String refunded = await settledBill(customerId: customerId);
      await settledBill(
        orderNumber: '20260409-0008',
        kotNumber: 'K20260409-0008',
        customerId: customerId,
      );

      await refundWholeBill(refunded);

      final CustomerSummary after = (await customers.loadSummary(customerId))
          .valueOrNull!;
      // ₹210 net across two visits.
      expect(after.averageOrderValue.paise, 10500);
    });

    test('the customer record and their order history both survive', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);

      await refundWholeBill(id);

      expect(
        (await customers.findByPhone('9000000001')).valueOrNull!.id,
        customerId,
      );
      final List<Order> history = (await orders.loadOrdersForCustomer(
        customerId,
      )).valueOrNull!;
      expect(history, hasLength(1));
      expect(history.single.id, id);
      expect(history.single.totalAmount.paise, 21000);
    });

    test('their last visit date does not move', () async {
      final String customerId = await seed.customer(phone: '9000000001');
      final String id = await settledBill(customerId: customerId);
      final DateTime? before = (await customers.loadSummary(customerId))
          .valueOrNull!
          .lastOrderAt;

      await refundWholeBill(id, at: DateTime(2026, 4, 10, 11));

      final DateTime? after = (await customers.loadSummary(customerId))
          .valueOrNull!
          .lastOrderAt;
      // The visit happened when it happened.
      expect(after, before);
    });

    test('a customer with no bills is unaffected by the refunds join', () async {
      final String customerId = await seed.customer(phone: '9000000002');

      final CustomerSummary summary = (await customers.loadSummary(customerId))
          .valueOrNull!;

      // The correlated subquery must not turn the LEFT JOIN into an inner one.
      expect(summary.completedOrderCount, 0);
      expect(summary.totalSpent.paise, 0);
      expect(summary.refundedTotal.paise, 0);
      expect(summary.netSpent.paise, 0);
      expect(summary.averageOrderValue.paise, 0);
    });

    test('a walk-in refund touches no customer at all', () async {
      final String id = await settledBill();

      expect((await refundWholeBill(id)).isOk, isTrue);

      expect((await customers.loadDirectory()).valueOrNull, isEmpty);
    });
  });

  group('history does not depend on the menu', () {
    test('repricing a dish after a refund changes no figure', () async {
      final MenuItem dish = (await menu.loadItems()).valueOrNull!.first;
      final String id = await settledBill(
        lines: <BillLineSpec>[BillLineSpec(menuItemId: dish.id)],
      );
      await refundWholeBill(id);
      final SalesSummary before = await summaryOf(thatDay);

      // The price rise the reports must survive.
      expect(
        (await menu.saveItem(
          dish.copyWith(basePrice: dish.basePrice + dish.basePrice),
        )).isOk,
        isTrue,
      );

      final SalesSummary after = await summaryOf(thatDay);
      expect(after.grossSales.paise, before.grossSales.paise);
      expect(after.refundTotal.paise, before.refundTotal.paise);
      expect(after.netSales.paise, before.netSales.paise);

      final Refund stored = (await refunds.loadForOrder(id))
          .valueOrNull!
          .single;
      expect(stored.amount.paise, 21000);
    });

    test('deleting a dish after a refund leaves the refund readable', () async {
      final MenuItem dish = (await menu.loadItems()).valueOrNull!.first;
      final String id = await settledBill(
        lines: <BillLineSpec>[BillLineSpec(menuItemId: dish.id)],
      );
      await refundWholeBill(id);

      expect((await menu.deleteItem(dish.id)).isOk, isTrue);

      // The reversal names the bill by a snapshot, so it does not need the dish to exist.
      final Refund stored = (await refunds.loadForOrder(id))
          .valueOrNull!
          .single;
      expect(stored.orderNumberSnapshot, '20260409-0001');
      expect(stored.amount.paise, 21000);

      final RefundableBill bill = (await refunds.loadRefundable(id))
          .valueOrNull!;
      expect(bill.refundedAmount.paise, 21000);
      expect(bill.refundableAmount.paise, 0);

      final SalesSummary summary = await summaryOf(thatDay);
      expect(summary.grossSales.paise, 21000);
      expect(summary.refundTotal.paise, 21000);
    });

    test('a bill can be refunded after its dish is deleted', () async {
      final MenuItem dish = (await menu.loadItems()).valueOrNull!.first;
      final String id = await settledBill(
        lines: <BillLineSpec>[BillLineSpec(menuItemId: dish.id)],
      );

      expect((await menu.deleteItem(dish.id)).isOk, isTrue);

      // Nothing on the refund path reads the menu, so a withdrawn dish cannot block giving
      // a customer their money back.
      final Result<Refund> outcome = await refundWholeBill(id);
      expect(outcome.isOk, isTrue);
      expect(outcome.valueOrNull!.amount.paise, 21000);
    });
  });
}
