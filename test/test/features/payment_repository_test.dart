import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqlitePaymentRepository payments;
  late SqliteOrderRepository orders;
  late Order order;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    payments = SqlitePaymentRepository(database: database);
    orders = SqliteOrderRepository(database: database);

    order = Fixtures.order(orderNumber: 'P-0001', total: '210.00');
    await orders.saveOrder(order);
  });

  tearDown(() async {
    await database.close();
  });

  test('a payment can be stored against an order', () async {
    final Payment payment = Fixtures.payment(
      orderId: order.id,
      method: PaymentMethod.upi,
      amount: '210.00',
      reference: 'TEST-UPI-1',
    );
    expect((await payments.record(payment)).isOk, isTrue);

    final List<Payment> stored = (await payments.loadForOrder(order.id))
        .valueOrNull!;

    expect(stored, hasLength(1));
    expect(stored.single.paymentMethod, PaymentMethod.upi);
    expect(stored.single.amount, Money.parse('210.00'));
    expect(stored.single.reference, 'TEST-UPI-1');
    expect(stored.single.status, PaymentStatus.completed);
  });

  test('every payment method is supported', () async {
    for (final PaymentMethod method in PaymentMethod.values) {
      final Payment payment = Fixtures.payment(
        orderId: order.id,
        method: method,
        amount: '10.00',
      );
      expect((await payments.record(payment)).isOk, isTrue);
    }

    final List<Payment> stored = (await payments.loadForOrder(order.id))
        .valueOrNull!;
    expect(
      stored.map((Payment p) => p.paymentMethod).toSet(),
      PaymentMethod.values.toSet(),
    );
  });

  test('an order can carry several payments, ready for split tender', () async {
    // No schema change is needed for this: the table is many-to-one by design.
    await payments.record(
      Fixtures.payment(
        orderId: order.id,
        method: PaymentMethod.cash,
        amount: '100.00',
        reference: null,
      ),
    );
    await payments.record(
      Fixtures.payment(
        orderId: order.id,
        method: PaymentMethod.upi,
        amount: '110.00',
      ),
    );

    final Money total = (await payments.settledTotalForOrder(order.id))
        .valueOrNull!;

    expect(total, Money.parse('210.00'));
    expect((await payments.loadForOrder(order.id)).valueOrNull, hasLength(2));
  });

  test('a pending payment does not count as collected', () async {
    await payments.record(
      Fixtures.payment(
        orderId: order.id,
        amount: '210.00',
        status: PaymentStatus.pending,
      ),
    );

    final Money total = (await payments.settledTotalForOrder(order.id))
        .valueOrNull!;
    expect(total, Money.zero);
  });

  test('a failed payment does not count as collected', () async {
    await payments.record(
      Fixtures.payment(
        orderId: order.id,
        amount: '210.00',
        status: PaymentStatus.failed,
      ),
    );

    expect(
      (await payments.settledTotalForOrder(order.id)).valueOrNull,
      Money.zero,
    );
  });

  test('the total is exact across many small payments', () async {
    for (int i = 0; i < 100; i++) {
      await payments.record(
        Fixtures.payment(
          orderId: order.id,
          amount: '0.01',
          reference: 'ref-$i',
        ),
      );
    }

    expect(
      (await payments.settledTotalForOrder(order.id)).valueOrNull,
      Money.parse('1.00'),
    );
  });

  test('an order with no payments totals zero, not an error', () async {
    final result = await payments.settledTotalForOrder(order.id);
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, Money.zero);
  });

  test('a payment against a missing order is rejected', () async {
    final result = await payments.record(
      Fixtures.payment(orderId: 'ord-does-not-exist'),
    );
    expect(result.isErr, isTrue);
  });

  test('a soft-deleted payment stops counting', () async {
    final Payment payment = Fixtures.payment(
      orderId: order.id,
      amount: '210.00',
    );
    await payments.record(payment);

    expect((await payments.delete(payment.id)).isOk, isTrue);

    expect((await payments.loadForOrder(order.id)).valueOrNull, isEmpty);
    expect(
      (await payments.settledTotalForOrder(order.id)).valueOrNull,
      Money.zero,
    );
  });
}
