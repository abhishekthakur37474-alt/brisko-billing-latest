import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/customers/domain/models/customer.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_match.dart';
import 'package:brisko_billing/features/customers/domain/models/customer_summary.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  test('a customer can be saved and retrieved by phone', () async {
    final Customer customer = Fixtures.customer(
      phone: '9812300001',
      name: 'Test Customer',
    );
    expect((await customers.save(customer)).isOk, isTrue);

    final Customer? found = (await customers.findByPhone('9812300001'))
        .valueOrNull;
    expect(found, isNotNull);
    expect(found!.id, customer.id);
    expect(found.name, 'Test Customer');
  });

  test('an unknown phone number returns null rather than failing', () async {
    final result = await customers.findByPhone('0000000000');
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('lookup ignores surrounding whitespace', () async {
    await customers.save(Fixtures.customer(phone: '9812300002'));
    expect(
      (await customers.findByPhone('  9812300002  ')).valueOrNull,
      isNotNull,
    );
  });

  test('findOrCreateByPhone creates once and reuses thereafter', () async {
    final Customer created = (await customers.findOrCreateByPhone(
      '9812300003',
      name: 'First',
    )).valueOrNull!;
    final Customer reused = (await customers.findOrCreateByPhone('9812300003'))
        .valueOrNull!;

    expect(reused.id, created.id);
    expect((await customers.loadAll()).valueOrNull, hasLength(1));
  });

  test('findOrCreateByPhone rejects an empty number', () async {
    final result = await customers.findOrCreateByPhone('   ');
    expect(result.isErr, isTrue);
    expect(result.failureOrNull, isA<ValidationFailure>());
    expect((await customers.loadAll()).valueOrNull, isEmpty);
  });

  test('findOrCreateByPhone refuses a number it cannot store', () async {
    for (final String bad in <String>[
      '12345',
      '98765',
      '9876543210123',
      '1123456789',
      'not a number',
    ]) {
      final result = await customers.findOrCreateByPhone(bad);
      expect(result.isErr, isTrue, reason: bad);
      expect(result.failureOrNull, isA<ValidationFailure>(), reason: bad);
    }
    // Nothing was created for any of them.
    expect((await customers.loadAll()).valueOrNull, isEmpty);
  });

  test('a number is stored in its normalised form', () async {
    final Customer created = (await customers.findOrCreateByPhone(
      '+91 98123 00010',
    )).valueOrNull!;

    expect(created.phone, '9812300010');
  });

  test('every way of writing one number reaches one record', () async {
    final Customer first = (await customers.findOrCreateByPhone('9812300011'))
        .valueOrNull!;

    for (final String same in <String>[
      '98123 00011',
      '+91 98123 00011',
      '+919812300011',
      '09812300011',
      '  9812300011  ',
    ]) {
      final Customer again = (await customers.findOrCreateByPhone(same))
          .valueOrNull!;
      expect(again.id, first.id, reason: same);
    }

    expect((await customers.loadAll()).valueOrNull, hasLength(1));
  });

  test('lookup normalises the number it is given', () async {
    await customers.findOrCreateByPhone('9812300012');

    expect(
      (await customers.findByPhone('+91 98123 00012')).valueOrNull,
      isNotNull,
    );
    expect((await customers.findByPhone('09812300012')).valueOrNull, isNotNull);
    // And a number that is not on file still misses quietly rather than failing.
    final result = await customers.findByPhone('9812399999');
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('a summary for a customer who is not on file is null', () async {
    final result = await customers.loadSummary('cus-not-here');
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('a summary for a customer with no bills is all zeroes', () async {
    final Customer created = (await customers.findOrCreateByPhone('9812300013'))
        .valueOrNull!;

    final CustomerSummary summary = (await customers.loadSummary(created.id))
        .valueOrNull!;

    expect(summary.phone, '9812300013');
    expect(summary.completedOrderCount, 0);
    expect(summary.totalSpent, Money.zero);
    expect(summary.lastOrderAt, isNull);
  });

  test('the directory limit is respected', () async {
    for (int index = 20; index < 25; index++) {
      await customers.findOrCreateByPhone('98123000$index');
    }

    expect((await customers.loadDirectory(limit: 3)).valueOrNull, hasLength(3));
    expect((await customers.loadDirectory()).valueOrNull, hasLength(5));
  });

  test('a customer with no name falls back to the phone number', () async {
    final Customer created = (await customers.findOrCreateByPhone('9812300004'))
        .valueOrNull!;
    expect(created.name, isNull);
    expect(created.displayName, '9812300004');
  });

  test('search matches on partial phone or name', () async {
    await customers.save(
      Fixtures.customer(phone: '9812345678', name: 'Test Alpha'),
    );
    await customers.save(
      Fixtures.customer(phone: '9887654321', name: 'Test Beta'),
    );

    expect((await customers.search('98123')).valueOrNull, hasLength(1));
    expect((await customers.search('Beta')).valueOrNull, hasLength(1));
    expect((await customers.search('Test')).valueOrNull, hasLength(2));
  });

  test('searchMatchesByName returns phone and last address', () async {
    final Customer ravi = (await customers.findOrCreateByPhone(
      '9000000101',
      name: 'Ravi',
    )).valueOrNull!;
    await orders.saveOrder(
      Fixtures.order(
        orderNumber: 'B-0001',
        status: OrderStatus.completed,
        customerId: ravi.id,
        customerName: 'Ravi',
        customerAddress: '12 Baraut Road',
      ),
    );

    final List<CustomerMatch> matches =
        (await customers.searchMatchesByName('Rav')).valueOrNull!;

    expect(matches, hasLength(1));
    expect(matches.single.name, 'Ravi');
    expect(matches.single.phone, '9000000101');
    expect(matches.single.address, '12 Baraut Road');
  });

  test('searchMatchesByName includes a walk-in name with no phone', () async {
    await orders.saveOrder(
      Fixtures.order(
        orderNumber: 'B-0002',
        status: OrderStatus.completed,
        customerName: 'Walk-in Ravi',
        customerAddress: 'Opp. library',
      ),
    );

    final List<CustomerMatch> matches =
        (await customers.searchMatchesByName('Walk-in')).valueOrNull!;

    expect(matches, hasLength(1));
    expect(matches.single.name, 'Walk-in Ravi');
    expect(matches.single.phone, isNull);
    expect(matches.single.address, 'Opp. library');
  });

  test('searchMatchesByName keeps two people with the same name apart', () async {
    await customers.findOrCreateByPhone('9000000102', name: 'Ravi');
    await customers.findOrCreateByPhone('9000000103', name: 'Ravi');

    final List<CustomerMatch> matches =
        (await customers.searchMatchesByName('Ravi')).valueOrNull!;

    expect(matches, hasLength(2));
    expect(
      matches.map((CustomerMatch match) => match.phone).toSet(),
      <String>{'9000000102', '9000000103'},
    );
  });

  test('findLastAddress returns the newest stored address', () async {
    final Customer ravi = (await customers.findOrCreateByPhone(
      '9000000104',
      name: 'Ravi',
    )).valueOrNull!;
    await orders.saveOrder(
      Fixtures.order(
        orderNumber: 'B-0003',
        status: OrderStatus.completed,
        customerId: ravi.id,
        customerName: 'Ravi',
        customerAddress: 'Old house',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await orders.saveOrder(
      Fixtures.order(
        orderNumber: 'B-0004',
        status: OrderStatus.completed,
        customerId: ravi.id,
        customerName: 'Ravi',
        customerAddress: 'New house',
        createdAt: DateTime.utc(2026, 2, 1),
      ),
    );

    expect(
      (await customers.findLastAddress(customerId: ravi.id)).valueOrNull,
      'New house',
    );
    expect(
      (await customers.findLastAddress(customerName: 'Ravi')).valueOrNull,
      'New house',
    );
  });

  test('a soft-deleted customer is hidden from lookup', () async {
    final Customer customer = Fixtures.customer(phone: '9812300005');
    await customers.save(customer);

    expect((await customers.delete(customer.id)).isOk, isTrue);

    expect((await customers.findByPhone('9812300005')).valueOrNull, isNull);
    expect((await customers.findById(customer.id)).valueOrNull, isNull);
    expect((await customers.loadAll()).valueOrNull, isEmpty);

    // Row retained so the deletion can be synchronised later.
    final List<Map<String, Object?>> raw = await database.database.query(
      'customers',
      where: 'id = ?',
      whereArgs: <Object?>[customer.id],
    );
    expect(raw.single['isDeleted'], 1);
  });
}
