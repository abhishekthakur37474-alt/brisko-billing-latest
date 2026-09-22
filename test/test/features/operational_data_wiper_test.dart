import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/sync/outbox_entry.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/expenses/data/repositories/sqlite_expense_repository.dart';
import 'package:brisko_billing/features/expenses/domain/models/expense.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/settings/data/file_till_backup_store.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/data/sqlite_operational_data_wiper.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteOutboxStore outbox;
  late SqliteOperationalDataWiper wiper;
  late SqliteSettingsRepository settings;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    outbox = SqliteOutboxStore(database: database);
    settings = SqliteSettingsRepository(database: database);
    wiper = SqliteOperationalDataWiper(
      database: database,
      outbox: outbox,
      settings: settings,
      backups: FileTillBackupStore(),
    );
  });

  tearDown(() async {
    await outbox.dispose();
    await database.close();
  });

  Future<int> count(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS count FROM $table',
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  test('a fresh install has a seeded menu and no bills', () async {
    expect(await count(SqliteTables.categories), greaterThan(0));
    expect(await count(SqliteTables.menuItems), greaterThan(0));
    expect(await count(SqliteTables.orders), 0);
  });

  test('clearing removes bills, the menu, orders and the upload queue', () async {
    final SqliteMenuRepository menu = SqliteMenuRepository(database: database);
    final SqliteOrderRepository orders = SqliteOrderRepository(
      database: database,
    );
    final SqliteCustomerRepository customers = SqliteCustomerRepository(
      database: database,
    );
    final SqliteExpenseRepository expenses = SqliteExpenseRepository(
      database: database,
    );

    expect((await customers.save(Fixtures.customer())).isOk, isTrue);
    final order = Fixtures.order(orderNumber: 'T-0001');
    expect(
      (await orders.saveOrder(
        order,
        items: <OrderItem>[Fixtures.orderItem(orderId: order.id)],
      )).isOk,
      isTrue,
    );
    expect(
      (await expenses.save(
        Expense(
          id: EntityId.generate(prefix: 'exp'),
          name: 'Test vegetables',
          amount: Money.parse('50.00'),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      )).isOk,
      isTrue,
    );
    expect(
      (await outbox.enqueue(
        OutboxEntry(
          id: EntityId.generate(prefix: 'obx'),
          collection: SqliteTables.orders,
          entityId: order.id,
          operation: OutboxOperation.upsert,
          payload: order.toMap(),
          queuedAt: DateTime.now().toUtc(),
        ),
      )).isOk,
      isTrue,
    );

    expect((await wiper.clearOperationalData()).isOk, isTrue);

    expect(await count(SqliteTables.categories), 0);
    expect(await count(SqliteTables.menuItems), 0);
    expect(await count(SqliteTables.menuItemVariants), 0);
    expect(await count(SqliteTables.menuItemOptions), 0);
    expect(await count(SqliteTables.orders), 0);
    expect(await count(SqliteTables.orderItems), 0);
    expect(await count(SqliteTables.customers), 0);
    expect(await count(SqliteTables.expenses), 0);
    expect(await count(SqliteTables.outbox), 0);
    expect((await menu.loadCategories()).valueOrNull, isEmpty);
  });

  test('clearing leaves the sign-in and outlet settings in place', () async {
    expect(
      (await settings.writeAll(<String, String?>{
        SettingKeys.businessName: 'Brisko Pizza Kothrud',
        FirebaseConfig.keyRefreshToken: 'refresh-token-for-tests',
        AuthSessionStore.keyAccountEmail: 'till@example.com',
      })).isOk,
      isTrue,
    );

    final SqliteSyncMetadataStore metadata = SqliteSyncMetadataStore(
      database: database,
    );
    expect(
      (await metadata.markBootstrapped()).isOk,
      isTrue,
    );

    expect((await wiper.clearOperationalData()).isOk, isTrue);

    final Map<String, String?> stored =
        (await settings.readAll()).valueOrNull ?? const <String, String?>{};
    expect(stored[SettingKeys.businessName], 'Brisko Pizza Kothrud');
    expect(stored[FirebaseConfig.keyRefreshToken], 'refresh-token-for-tests');
    expect(stored[AuthSessionStore.keyAccountEmail], 'till@example.com');
    expect((await metadata.isBootstrapped()).valueOrNull, isTrue);
  });
}
