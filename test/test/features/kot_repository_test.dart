import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_item.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_record.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteKotRepository kots;
  late SqliteOrderRepository orders;
  late Order order;
  late OrderItem orderItem;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    kots = SqliteKotRepository(database: database);
    orders = SqliteOrderRepository(database: database);

    order = Fixtures.order(orderNumber: 'K-0001');
    orderItem = Fixtures.orderItem(orderId: order.id);
    await orders.saveOrder(order, items: <OrderItem>[orderItem]);
  });

  tearDown(() async {
    await database.close();
  });

  test('a slip can be created for an order with its lines', () async {
    final String number = (await kots.nextKotNumber()).valueOrNull!;
    final KotRecord record = Fixtures.kotRecord(
      orderId: order.id,
      kotNumber: number,
    );
    final KotItem item = Fixtures.kotItem(
      kotId: record.id,
      orderItemId: orderItem.id,
      itemName: 'Test Pizza',
      variantName: 'Medium',
      quantity: 2,
      notes: 'no onion',
    );

    expect((await kots.createKot(record, <KotItem>[item])).isOk, isTrue);

    final KotRecord? loaded = (await kots.findKot(record.id)).valueOrNull;
    expect(loaded, isNotNull);
    expect(loaded!.status, KotStatus.pending);
    expect(loaded.kotNumber, number);

    final List<KotItem> lines = (await kots.loadItems(record.id)).valueOrNull!;
    expect(lines, hasLength(1));
    expect(lines.single.displayName, 'Test Pizza (Medium)');
    expect(lines.single.notes, 'no onion');
  });

  test('slip lines carry name snapshots, not menu lookups', () async {
    final KotRecord record = Fixtures.kotRecord(
      orderId: order.id,
      kotNumber: (await kots.nextKotNumber()).valueOrNull!,
    );
    await kots.createKot(record, <KotItem>[
      Fixtures.kotItem(
        kotId: record.id,
        orderItemId: orderItem.id,
        itemName: 'Name At Print Time',
        variantName: 'Large',
      ),
    ]);

    final KotItem line = (await kots.loadItems(record.id)).valueOrNull!.single;
    expect(line.itemNameSnapshot, 'Name At Print Time');
    expect(line.variantNameSnapshot, 'Large');
  });

  test('slip numbers increment within the day', () async {
    final String first = (await kots.nextKotNumber()).valueOrNull!;
    expect(first, matches(RegExp(r'^K\d{8}-0001$')));

    await kots.createKot(
      Fixtures.kotRecord(orderId: order.id, kotNumber: first),
      const <KotItem>[],
    );

    final String second = (await kots.nextKotNumber()).valueOrNull!;
    expect(second, endsWith('-0002'));
  });

  test('an order can have more than one slip', () async {
    // Items added after the first slip went to the kitchen need their own slip.
    final String first = (await kots.nextKotNumber()).valueOrNull!;
    await kots.createKot(
      Fixtures.kotRecord(orderId: order.id, kotNumber: first),
      const <KotItem>[],
    );
    final String second = (await kots.nextKotNumber()).valueOrNull!;
    await kots.createKot(
      Fixtures.kotRecord(orderId: order.id, kotNumber: second),
      const <KotItem>[],
    );

    expect((await kots.loadForOrder(order.id)).valueOrNull, hasLength(2));
  });

  test('a duplicate slip number is rejected', () async {
    final String number = (await kots.nextKotNumber()).valueOrNull!;
    await kots.createKot(
      Fixtures.kotRecord(orderId: order.id, kotNumber: number),
      const <KotItem>[],
    );

    final result = await kots.createKot(
      Fixtures.kotRecord(orderId: order.id, kotNumber: number),
      const <KotItem>[],
    );
    expect(result.isErr, isTrue);
  });

  test('pending slips are the ones still needing paper', () async {
    final KotRecord pending = Fixtures.kotRecord(
      orderId: order.id,
      kotNumber: (await kots.nextKotNumber()).valueOrNull!,
    );
    await kots.createKot(pending, const <KotItem>[]);

    expect((await kots.loadPending()).valueOrNull, hasLength(1));
    expect(pending.status.needsPrinting, isTrue);

    // Marked printed once the shared thermal printer has produced the slip.
    expect(
      (await kots.updateStatus(pending.id, KotStatus.printed)).isOk,
      isTrue,
    );

    expect((await kots.loadPending()).valueOrNull, isEmpty);
    final KotRecord reloaded = (await kots.findKot(pending.id)).valueOrNull!;
    expect(reloaded.status, KotStatus.printed);
  });

  test('status moves through the full workflow', () async {
    final KotRecord record = Fixtures.kotRecord(
      orderId: order.id,
      kotNumber: (await kots.nextKotNumber()).valueOrNull!,
    );
    await kots.createKot(record, const <KotItem>[]);

    for (final KotStatus status in <KotStatus>[
      KotStatus.printed,
      KotStatus.completed,
      KotStatus.cancelled,
    ]) {
      expect((await kots.updateStatus(record.id, status)).isOk, isTrue);
      expect((await kots.findKot(record.id)).valueOrNull!.status, status);
    }
  });

  test('a slip against a missing order is rejected', () async {
    final result = await kots.createKot(
      Fixtures.kotRecord(orderId: 'ord-does-not-exist', kotNumber: 'K-X'),
      const <KotItem>[],
    );
    expect(result.isErr, isTrue);
  });
}
