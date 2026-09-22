import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_local_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/sync/remote_merge_report.dart';
import 'package:brisko_billing/core/data/sync/sync_state.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/payments/domain/models/refund.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_database.dart';

/// Regression tests for the Windows sync failure reported as
/// "That record already exists.".
///
/// Root cause: a pulled cloud document could carry a *new* stable id while sharing a
/// *natural* unique key — an `orderNumber`, a once-per-order refund — with a different
/// local row. The merge upserted with `ON CONFLICT (id)`, which cannot absorb a
/// collision on a secondary unique index, so SQLite raised a UNIQUE error that surfaced
/// as "That record already exists." and failed the whole pull.
///
/// These tests exercise the merge (`applyRemoteChanges`, the download half of sync)
/// directly, since that is where the write happened. They lock in that the pull is now
/// idempotent and last-write-wins is preserved on the natural key, not just on the id.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteLocalStore<Order> orders;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    orders = SqliteLocalStore<Order>(
      database: database,
      table: SqliteTables.orders,
      fromRow: Order.fromRow,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Order orderAt(
    String id,
    String number,
    DateTime at, {
    String total = '100.00',
    bool isDeleted = false,
  }) => Order(
    id: id,
    orderNumber: number,
    orderType: OrderType.takeaway,
    status: OrderStatus.completed,
    subtotal: Money.parse(total),
    discountAmount: Money.zero,
    taxAmount: Money.zero,
    totalAmount: Money.parse(total),
    createdAt: at,
    updatedAt: at,
    isDeleted: isDeleted,
    syncState: SyncState.pending,
  );

  Future<Order?> byId(String id) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      SqliteTables.orders,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : Order.fromRow(rows.first);
  }

  Future<int> orderCount(String number) async {
    final List<Map<String, Object?>> rows = await database.database.query(
      SqliteTables.orders,
      where: 'orderNumber = ?',
      whereArgs: <Object?>[number],
    );
    return rows.length;
  }

  group('remote document does not exist locally', () {
    test('a create succeeds and is stored as synced', () async {
      final RemoteMergeReport report = (await orders.applyRemoteChanges(
        <Order>[orderAt('remote-1', 'A-001', DateTime.utc(2026, 1, 1))],
      )).valueOrNull!;

      expect(report.applied, 1);
      expect(report.keptLocal, 0);
      final Order? stored = await byId('remote-1');
      expect(stored, isNotNull);
      expect(stored!.syncState, SyncState.synced);
    });
  });

  group('remote document already exists with the same stable id', () {
    test('re-applying identical data is idempotent (no duplicate)', () async {
      final Order remote = orderAt('id-1', 'A-002', DateTime.utc(2026, 1, 1));

      final Result<RemoteMergeReport> first = await orders.applyRemoteChanges(
        <Order>[remote],
      );
      // Second pull with the same (equal-timestamp) record: last-write-wins holds it
      // back, and crucially it does not throw or duplicate.
      final Result<RemoteMergeReport> second = await orders.applyRemoteChanges(
        <Order>[remote],
      );

      expect(first.isOk, isTrue);
      expect(second.isOk, isTrue);
      expect(await orderCount('A-002'), 1);
    });
  });

  group('last-write-wins on the stable id is preserved', () {
    test('a strictly newer remote record overwrites the local one', () async {
      await orders.applyRemoteChanges(<Order>[
        orderAt('id-2', 'A-003', DateTime.utc(2026, 1, 1), total: '100.00'),
      ]);

      final RemoteMergeReport report = (await orders.applyRemoteChanges(
        <Order>[
          orderAt('id-2', 'A-003', DateTime.utc(2026, 1, 2), total: '250.00'),
        ],
      )).valueOrNull!;

      expect(report.applied, 1);
      expect((await byId('id-2'))!.totalAmount, Money.parse('250.00'));
    });

    test('an older remote record is held back so local wins', () async {
      await orders.save(
        orderAt('id-3', 'A-004', DateTime.utc(2026, 1, 2), total: '999.00'),
      );

      final RemoteMergeReport report = (await orders.applyRemoteChanges(
        <Order>[
          orderAt('id-3', 'A-004', DateTime.utc(2026, 1, 1), total: '1.00'),
        ],
      )).valueOrNull!;

      expect(report.applied, 0);
      expect(report.keptLocal, 1);
      expect((await byId('id-3'))!.totalAmount, Money.parse('999.00'));
    });
  });

  group(
    'remote document shares a natural unique key under a different id '
    '(the reported bug)',
    () {
      test(
        'no longer fails with "That record already exists."',
        () async {
          await orders.save(
            orderAt('local-1', 'A-100', DateTime.utc(2026, 1, 1)),
          );

          final Result<RemoteMergeReport> result = await orders
              .applyRemoteChanges(<Order>[
                orderAt('remote-1', 'A-100', DateTime.utc(2026, 1, 2)),
              ]);

          expect(
            result.isOk,
            isTrue,
            reason:
                'a pulled row sharing orderNumber A-100 must merge, not fail '
                'the pull',
          );
        },
      );

      test(
        'newer remote wins: the duplicate collapses to the remote id',
        () async {
          await orders.save(
            orderAt('local-1', 'A-101', DateTime.utc(2026, 1, 1), total: '5.00'),
          );

          final RemoteMergeReport report = (await orders.applyRemoteChanges(
            <Order>[
              orderAt(
                'remote-1',
                'A-101',
                DateTime.utc(2026, 1, 2),
                total: '9.00',
              ),
            ],
          )).valueOrNull!;

          expect(report.applied, 1);
          // The natural key still identifies exactly one bill.
          expect(await orderCount('A-101'), 1);
          // And it is the newer, remote version, under the remote id.
          final Order? remote = await byId('remote-1');
          expect(remote, isNotNull);
          expect(remote!.totalAmount, Money.parse('9.00'));
          expect(remote.syncState, SyncState.synced);
          // The superseded older local duplicate is gone.
          expect(await byId('local-1'), isNull);
        },
      );

      test(
        'older remote loses: local wins and is untouched',
        () async {
          await orders.save(
            orderAt(
              'local-1',
              'A-102',
              DateTime.utc(2026, 1, 2),
              total: '77.00',
            ),
          );

          final RemoteMergeReport report = (await orders.applyRemoteChanges(
            <Order>[
              orderAt(
                'remote-1',
                'A-102',
                DateTime.utc(2026, 1, 1),
                total: '1.00',
              ),
            ],
          )).valueOrNull!;

          expect(report.applied, 0);
          expect(report.keptLocal, 1);
          // The local bill stands, under its own id, unchanged. The older remote
          // duplicate was not inserted.
          expect(await orderCount('A-102'), 1);
          final Order? local = await byId('local-1');
          expect(local, isNotNull);
          expect(local!.totalAmount, Money.parse('77.00'));
          expect(await byId('remote-1'), isNull);
        },
      );

      test(
        'a whole batch still applies when one row collides on the natural key',
        () async {
          await orders.save(
            orderAt('local-1', 'B-001', DateTime.utc(2026, 1, 1)),
          );

          // One row is the colliding duplicate; the others are ordinary new bills.
          // Before the fix the collision threw and lost the entire batch.
          final RemoteMergeReport report = (await orders.applyRemoteChanges(
            <Order>[
              orderAt('remote-1', 'B-001', DateTime.utc(2026, 1, 2)),
              orderAt('remote-2', 'B-002', DateTime.utc(2026, 1, 2)),
              orderAt('remote-3', 'B-003', DateTime.utc(2026, 1, 2)),
            ],
          )).valueOrNull!;

          expect(report.applied, 3);
          expect(await byId('remote-2'), isNotNull);
          expect(await byId('remote-3'), isNotNull);
        },
      );

      test(
        'collapsing a duplicate order that still has children does not fail '
        'with FOREIGN KEY constraint failed',
        () async {
          // The reported Windows pull failure: cloud delete of order
          // `ord-muaro0vsg7wlftm0` hit SQLITE 1811 because local children
          // (order_items, payments, kot_records, …) still referenced it under
          // ON DELETE RESTRICT. Same shape here: a newer remote bill shares
          // orderNumber with a local bill that already has a line.
          await orders.save(
            orderAt('local-1', 'A-FK', DateTime.utc(2026, 1, 1)),
          );
          await database.database.insert(SqliteTables.orderItems, <String, Object?>{
            'id': 'item-local',
            'createdAt': 0,
            'updatedAt': 0,
            'isDeleted': 0,
            'syncState': 'synced',
            'orderId': 'local-1',
            'itemNameSnapshot': 'Farmhouse',
            'quantity': 1,
            'unitPricePaise': 10000,
            'discountAmountPaise': 0,
            'taxAmountPaise': 0,
            'totalAmountPaise': 10000,
          });
          await database.database.insert(
            SqliteTables.orderItemOptions,
            <String, Object?>{
              'id': 'opt-local',
              'createdAt': 0,
              'updatedAt': 0,
              'isDeleted': 0,
              'syncState': 'synced',
              'orderItemId': 'item-local',
              'optionNameSnapshot': 'Extra Cheese',
              'pricePaise': 2000,
              'quantity': 1,
            },
          );
          await database.database.insert(SqliteTables.payments, <String, Object?>{
            'id': 'pay-local',
            'createdAt': 0,
            'updatedAt': 0,
            'isDeleted': 0,
            'syncState': 'synced',
            'orderId': 'local-1',
            'paymentMethod': PaymentMethod.cash.name,
            'amountPaise': 10000,
            'reference': null,
            'status': PaymentStatus.completed.name,
          });

          final Result<RemoteMergeReport> result = await orders
              .applyRemoteChanges(<Order>[
                orderAt('remote-1', 'A-FK', DateTime.utc(2026, 1, 2)),
              ]);

          expect(
            result.isOk,
            isTrue,
            reason: 'must not fail with FOREIGN KEY constraint failed',
          );
          expect(result.valueOrNull!.applied, 1);
          expect(await byId('remote-1'), isNotNull);
          expect(await byId('local-1'), isNull);

          final List<Map<String, Object?>> leftoverItems = await database
              .database
              .query(
                SqliteTables.orderItems,
                where: 'orderId = ?',
                whereArgs: <Object?>['local-1'],
              );
          expect(leftoverItems, isEmpty);
          final List<Map<String, Object?>> leftoverOptions = await database
              .database
              .query(
                SqliteTables.orderItemOptions,
                where: 'id = ?',
                whereArgs: <Object?>['opt-local'],
              );
          expect(leftoverOptions, isEmpty);
          final List<Map<String, Object?>> leftoverPayments = await database
              .database
              .query(
                SqliteTables.payments,
                where: 'orderId = ?',
                whereArgs: <Object?>['local-1'],
              );
          expect(leftoverPayments, isEmpty);
        },
      );
    },
  );

  group('partial unique index (soft-delete aware) is honoured', () {
    late SqliteLocalStore<Refund> refunds;

    setUp(() async {
      refunds = SqliteLocalStore<Refund>(
        database: database,
        table: SqliteTables.refunds,
        fromRow: Refund.fromRow,
      );

      // refunds references orders and payments, so seed the parents the FK needs.
      await database.database.insert(SqliteTables.orders, <String, Object?>{
        'id': 'ord-1',
        'createdAt': 0,
        'updatedAt': 0,
        'isDeleted': 0,
        'syncState': 'synced',
        'orderNumber': 'R-001',
        'orderType': OrderType.takeaway.name,
        'status': OrderStatus.completed.name,
        'subtotalPaise': 10000,
        'discountAmountPaise': 0,
        'taxAmountPaise': 0,
        'totalAmountPaise': 10000,
      });
      await database.database.insert(SqliteTables.payments, <String, Object?>{
        'id': 'pay-1',
        'createdAt': 0,
        'updatedAt': 0,
        'isDeleted': 0,
        'syncState': 'synced',
        'orderId': 'ord-1',
        'paymentMethod': PaymentMethod.upi.name,
        'amountPaise': 10000,
        'reference': null,
        'status': PaymentStatus.completed.name,
      });
    });

    Refund refundAt(String id, DateTime at, {bool isDeleted = false}) => Refund(
      id: id,
      orderId: 'ord-1',
      paymentId: 'pay-1',
      orderNumberSnapshot: 'R-001',
      paymentMethod: PaymentMethod.upi,
      amount: Money.parse('50.00'),
      status: PaymentStatus.completed,
      createdAt: at,
      updatedAt: at,
      isDeleted: isDeleted,
      syncState: SyncState.pending,
    );

    test(
      'a soft-deleted local refund is not treated as a blocker, so a new '
      'refund for the same order can be pulled',
      () async {
        // The unique index on refunds is partial: UNIQUE(orderId) WHERE isDeleted = 0.
        // A soft-deleted refund is outside it, so a genuinely new refund for the same
        // order must merge rather than be mistaken for a conflict and dropped.
        await refunds.save(
          refundAt('ref-old', DateTime.utc(2026, 1, 1), isDeleted: true),
        );

        final Result<RemoteMergeReport> result = await refunds
            .applyRemoteChanges(<Refund>[
              refundAt('ref-new', DateTime.utc(2026, 1, 2)),
            ]);

        expect(result.isOk, isTrue);
        expect(result.valueOrNull!.applied, 1);
        // Both rows exist: the newer active refund was created, the soft-deleted one
        // was left alone rather than being deleted as a false "duplicate".
        final List<Map<String, Object?>> all = await database.database.query(
          SqliteTables.refunds,
        );
        expect(all.map((Map<String, Object?> r) => r['id']), <String>{
          'ref-old',
          'ref-new',
        });
      },
    );

    test(
      'two active refunds for the same order still resolve by last-write-wins',
      () async {
        await refunds.save(refundAt('ref-a', DateTime.utc(2026, 1, 1)));

        final RemoteMergeReport report = (await refunds.applyRemoteChanges(
          <Refund>[refundAt('ref-b', DateTime.utc(2026, 1, 2))],
        )).valueOrNull!;

        expect(report.applied, 1);
        // The active-refund uniqueness on orderId still holds: one active row.
        final List<Map<String, Object?>> active = await database.database.query(
          SqliteTables.refunds,
          where: 'orderId = ? AND isDeleted = 0',
          whereArgs: <Object?>['ord-1'],
        );
        expect(active, hasLength(1));
        expect(active.first['id'], 'ref-b');
      },
    );
  });

  group('foreign key constraint handling when parent is missing or held back', () {
    late SqliteLocalStore<OrderItem> orderItems;

    setUp(() {
      orderItems = SqliteLocalStore<OrderItem>(
        database: database,
        table: SqliteTables.orderItems,
        fromRow: OrderItem.fromRow,
      );
    });

    OrderItem itemAt(
      String id,
      String orderId,
      DateTime at, {
      String name = 'Test Item',
      bool isDeleted = false,
    }) => OrderItem(
      id: id,
      orderId: orderId,
      itemNameSnapshot: name,
      quantity: 1,
      unitPrice: Money.parse('100.00'),
      totalAmount: Money.parse('100.00'),
      createdAt: at,
      updatedAt: at,
      isDeleted: isDeleted,
    );

    test(
      'pulling an item referencing a missing parent order does not throw foreign key failure',
      () async {
        // Parent order does not exist locally (for instance, because it was held
        // back by LWW during the orders pull).
        final Result<RemoteMergeReport> result = await orderItems.applyRemoteChanges(
          <OrderItem>[
            itemAt('item-orphaned', 'ord-missing', DateTime.utc(2026, 1, 1)),
          ],
        );

        expect(result.isOk, isTrue, reason: 'must not fail with FOREIGN KEY constraint failed');
        final RemoteMergeReport report = result.valueOrNull!;
        expect(report.applied, 0);
        expect(report.keptLocal, 1);

        // No orphaned item was inserted.
        final List<Map<String, Object?>> rows = await database.database.query(
          SqliteTables.orderItems,
          where: 'id = ?',
          whereArgs: <Object?>['item-orphaned'],
        );
        expect(rows, isEmpty);
      },
    );

    test(
      'batch with valid and orphaned items applies valid items and holds back orphans',
      () async {
        // Seed an existing order.
        await orders.save(orderAt('ord-valid', 'V-001', DateTime.utc(2026, 1, 1)));

        final Result<RemoteMergeReport> result = await orderItems.applyRemoteChanges(
          <OrderItem>[
            itemAt('item-1', 'ord-valid', DateTime.utc(2026, 1, 1), name: 'Valid Item'),
            itemAt('item-2', 'ord-missing', DateTime.utc(2026, 1, 1), name: 'Orphan Item'),
          ],
        );

        expect(result.isOk, isTrue);
        final RemoteMergeReport report = result.valueOrNull!;
        expect(report.applied, 1);
        expect(report.keptLocal, 1);

        final List<Map<String, Object?>> valid = await database.database.query(
          SqliteTables.orderItems,
          where: 'id = ?',
          whereArgs: <Object?>['item-1'],
        );
        expect(valid, hasLength(1));

        final List<Map<String, Object?>> orphan = await database.database.query(
          SqliteTables.orderItems,
          where: 'id = ?',
          whereArgs: <Object?>['item-2'],
        );
        expect(orphan, isEmpty);
      },
    );

    test(
      'end-to-end: older remote order held back by LWW does not cause its items to fail sync',
      () async {
        // Local has a newer order for number 'A-999'.
        await orders.save(
          orderAt('local-ord', 'A-999', DateTime.utc(2026, 1, 2)),
        );

        // Cloud has an older order with same number 'A-999' under a different ID.
        final RemoteMergeReport orderReport = (await orders.applyRemoteChanges(
          <Order>[
            orderAt('remote-ord', 'A-999', DateTime.utc(2026, 1, 1)),
          ],
        )).valueOrNull!;
        // Remote order was held back under LWW.
        expect(orderReport.applied, 0);
        expect(orderReport.keptLocal, 1);

        // Next, cloud items for 'remote-ord' arrive in the sync sequence.
        final Result<RemoteMergeReport> itemResult = await orderItems.applyRemoteChanges(
          <OrderItem>[
            itemAt('remote-item', 'remote-ord', DateTime.utc(2026, 1, 1)),
          ],
        );

        // Must succeed cleanly without FOREIGN KEY constraint failure.
        expect(itemResult.isOk, isTrue);
        expect(itemResult.valueOrNull!.applied, 0);
        expect(itemResult.valueOrNull!.keptLocal, 1);
      },
    );
  });
}
