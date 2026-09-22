import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:brisko_billing/features/payments/domain/models/refund_request.dart';
import 'package:brisko_billing/features/payments/domain/models/refundable_bill.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/flaky_database.dart';
import '../helpers/seeded_sales.dart';
import '../helpers/test_database.dart';

/// A refund that fails, and what it must leave behind: nothing.
///
/// ## Why this needs an injected fault
///
/// Every other refusal in this feature is a business rule, checked before or inside the
/// transaction, so nothing was ever written. This file covers the other kind of failure — the
/// storage itself going wrong mid-write — which is the only way a half-finished refund could
/// exist. It is unreachable without injecting it, and it is the case that would cost real
/// money, so it is injected.
void main() {
  setUpAll(TestDatabase.register);

  final DateTime billedAt = DateTime(2026, 4, 9, 13, 30);
  final DateTime refundedAt = DateTime(2026, 4, 9, 15, 5);

  late FlakyDatabaseFactory factory;
  late SqliteDatabase database;
  late SeededSales seed;
  late SqliteRefundRepository refunds;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;

  setUp(() async {
    factory = FlakyDatabaseFactory();
    database = SqliteDatabase(factory: factory);
    await database.open(path: SqliteDatabase.inMemoryPath);
    seed = SeededSales(database);
    refunds = SqliteRefundRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
  });

  tearDown(() async {
    factory.allowAllWrites();
    await database.close();
  });

  Future<String> settledBill() => seed.bill(
    orderNumber: '20260409-0001',
    at: billedAt,
    kotNumber: 'K20260409-0001',
  );

  Future<int> rowsIn(String table) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      table,
    );
    return rows.length;
  }

  Future<RefundRequest> requestFor(String orderId) async {
    final RefundableBill bill = (await refunds.loadRefundable(orderId))
        .valueOrNull!;
    return RefundRequest.forBill(bill, at: refundedAt);
  }

  group('a refund that cannot be written', () {
    test('is reported as a failure rather than a success', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);
      factory.reset();
      // The single insert the refund makes is refused.
      factory.failAfterWrites = 0;

      final Result<Refund> outcome = await refunds.refund(request);

      expect(outcome.isErr, isTrue);
      // An injected fault is not a rule violation, so it surfaces as unexpected rather than
      // as something the cashier did wrong.
      expect(outcome.failureOrNull, isA<UnexpectedFailure>());
    });

    test('leaves no refund row behind', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);
      factory.reset();
      factory.failAfterWrites = 0;

      await refunds.refund(request);
      factory.allowAllWrites();

      expect(await rowsIn(SqliteTables.refunds), 0);
      expect((await refunds.loadForOrder(id)).valueOrNull, isEmpty);
    });

    test('leaves the original sale exactly as it was', () async {
      final String id = await settledBill();
      final Order billBefore = (await orders.findOrder(id)).valueOrNull!;
      final Payment tenderBefore = (await payments.loadForOrder(id))
          .valueOrNull!
          .single;
      final RefundRequest request = await requestFor(id);
      factory.reset();
      factory.failAfterWrites = 0;

      expect((await refunds.refund(request)).isErr, isTrue);
      factory.allowAllWrites();

      final Order billAfter = (await orders.findOrder(id)).valueOrNull!;
      expect(billAfter.status, OrderStatus.completed);
      expect(billAfter.totalAmount.paise, billBefore.totalAmount.paise);
      expect(billAfter.updatedAt, billBefore.updatedAt);

      final Payment tenderAfter = (await payments.loadForOrder(id))
          .valueOrNull!
          .single;
      expect(tenderAfter.id, tenderBefore.id);
      expect(tenderAfter.status, PaymentStatus.completed);
      expect(tenderAfter.amount.paise, tenderBefore.amount.paise);
      expect(tenderAfter.updatedAt, tenderBefore.updatedAt);

      // And every other table the sale lives in is untouched.
      expect(await rowsIn(SqliteTables.orders), 1);
      expect(await rowsIn(SqliteTables.orderItems), 1);
      expect(await rowsIn(SqliteTables.payments), 1);
      expect(await rowsIn(SqliteTables.kotRecords), 1);
    });

    test('leaves the bill still fully refundable', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);
      factory.reset();
      factory.failAfterWrites = 0;

      await refunds.refund(request);
      factory.allowAllWrites();

      final RefundableBill bill = (await refunds.loadRefundable(id))
          .valueOrNull!;
      expect(bill.refundedAmount.paise, 0);
      expect(bill.refundableAmount.paise, 21000);
      expect(bill.hasRefund, isFalse);
      expect(bill.canRefund, isTrue);
    });

    test(
      'can be retried with the same request once the fault clears',
      () async {
        final String id = await settledBill();
        final RefundRequest request = await requestFor(id);
        factory.reset();
        factory.failAfterWrites = 0;

        expect((await refunds.refund(request)).isErr, isTrue);

        factory.allowAllWrites();

        // Nothing committed, so the id is free and the held request goes through. This is the
        // case the fixed request id exists for.
        final Result<Refund> retried = await refunds.refund(request);
        expect(retried.isOk, isTrue);
        expect(retried.valueOrNull!.id, request.id);
        expect(retried.valueOrNull!.amount.paise, 21000);
        expect(await rowsIn(SqliteTables.refunds), 1);
      },
    );

    test('retrying twice after a fault still refunds once', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);
      factory.reset();
      factory.failAfterWrites = 0;

      expect((await refunds.refund(request)).isErr, isTrue);
      factory.allowAllWrites();

      expect((await refunds.refund(request)).isOk, isTrue);
      expect((await refunds.refund(request)).isOk, isTrue);

      expect(await rowsIn(SqliteTables.refunds), 1);
      expect(
        (await refunds.loadRefundable(id)).valueOrNull!.refundedAmount.paise,
        21000,
      );
    });
  });

  group('a rule refusal writes nothing at all', () {
    test(
      'a refused refund makes no write, not even a rolled back one',
      () async {
        final String id = await settledBill();
        await orders.cancelOrder(id);
        final RefundableBill bill = (await refunds.loadRefundable(id))
            .valueOrNull!;
        factory.reset();
        // Any write whatsoever would fail here, so a refusal that reached one would show up as
        // an unexpected failure rather than a validation failure.
        factory.failAfterWrites = 0;

        final Result<Refund> refused = await refunds.refund(
          RefundRequest(
            id: 'ref-on-a-cancelled-bill',
            orderId: bill.orderId,
            amount: bill.paidAmount,
            requestedAt: refundedAt,
          ),
        );

        expect(refused.isErr, isTrue);
        expect(refused.failureOrNull, isA<ValidationFailure>());
        expect(refused.failureOrNull!.message, contains('was cancelled'));
      },
    );

    test(
      'a refund of nothing is refused before the transaction opens',
      () async {
        final String id = await settledBill();
        factory.reset();
        factory.failAfterWrites = 0;

        final Result<Refund> refused = await refunds.refund(
          RefundRequest(
            id: 'ref-zero',
            orderId: id,
            amount: const Money.fromPaise(0),
            requestedAt: refundedAt,
          ),
        );

        expect(refused.isErr, isTrue);
        expect(refused.failureOrNull, isA<ValidationFailure>());
        expect(refused.failureOrNull!.message, contains('more than nothing'));
      },
    );
  });

  group('watchers are woken only after the commit', () {
    test('a successful refund announces the refunds table', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);

      final List<String> announced = <String>[];
      final sub = database.tableChanges.listen(announced.add);
      addTearDown(sub.cancel);

      expect((await refunds.refund(request)).isOk, isTrue);
      // Let the broadcast stream deliver.
      await Future<void>.delayed(Duration.zero);

      expect(announced, contains(SqliteTables.refunds));
      // The row is on disk by the time anything is told about it, so a watcher that re-reads
      // immediately sees the committed reversal rather than one that might roll back.
      expect(await rowsIn(SqliteTables.refunds), 1);
    });

    test('a failed refund announces nothing', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);

      final List<String> announced = <String>[];
      final sub = database.tableChanges.listen(announced.add);
      addTearDown(sub.cancel);

      factory.reset();
      factory.failAfterWrites = 0;
      expect((await refunds.refund(request)).isErr, isTrue);
      await Future<void>.delayed(Duration.zero);
      factory.allowAllWrites();

      expect(announced, isEmpty);
    });

    test('a refund does not announce the payments table', () async {
      // Nothing in `payments` is written, so nothing watching it has anything new to see.
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);

      final List<String> announced = <String>[];
      final sub = database.tableChanges.listen(announced.add);
      addTearDown(sub.cancel);

      expect((await refunds.refund(request)).isOk, isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(announced, isNot(contains(SqliteTables.payments)));
      expect(announced, isNot(contains(SqliteTables.orders)));
      expect(announced, isNot(contains(SqliteTables.kotRecords)));
    });
  });

  group('a refund is one write', () {
    test('it touches only the refunds table', () async {
      final String id = await settledBill();
      final RefundRequest request = await requestFor(id);

      final int ordersBefore = await rowsIn(SqliteTables.orders);
      final int itemsBefore = await rowsIn(SqliteTables.orderItems);
      final int paymentsBefore = await rowsIn(SqliteTables.payments);
      final int kotsBefore = await rowsIn(SqliteTables.kotRecords);
      final int movementsBefore = await rowsIn(SqliteTables.stockMovements);

      expect((await refunds.refund(request)).isOk, isTrue);

      expect(await rowsIn(SqliteTables.orders), ordersBefore);
      expect(await rowsIn(SqliteTables.orderItems), itemsBefore);
      expect(await rowsIn(SqliteTables.payments), paymentsBefore);
      expect(await rowsIn(SqliteTables.kotRecords), kotsBefore);
      // No stock movement, of any type. In particular no `adjustment`, which would put an
      // automatic reversal in the ledger dressed as a human decision.
      expect(await rowsIn(SqliteTables.stockMovements), movementsBefore);
      expect(await rowsIn(SqliteTables.stockMovements), 0);
      expect(await rowsIn(SqliteTables.refunds), 1);
    });

    test(
      'no stock movement is written even for a bill with a deduction',
      () async {
        final String id = await settledBill();

        expect((await refunds.refund(await requestFor(id))).isOk, isTrue);

        final List<Map<String, Object?>> movements = await database.database
            .query(SqliteTables.stockMovements);
        expect(movements, isEmpty);
        // And the deduction ledger gained no row either.
        expect(await rowsIn(SqliteTables.orderInventoryDeductions), 0);
      },
    );
  });
}
