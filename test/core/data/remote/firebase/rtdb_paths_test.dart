import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/core/data/remote/firebase/rtdb_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RtdbPaths', () {
    test('maps local table names to camelCase RTDB nodes', () {
      expect(RtdbPaths.resolve(SqliteTables.orders), 'orders');
      expect(RtdbPaths.resolve(SqliteTables.orderItems), 'orderItems');
      expect(RtdbPaths.resolve(SqliteTables.menuItems), 'menuItems');
      expect(RtdbPaths.resolve(SqliteTables.kotItemOptions), 'kotItemOptions');
      expect(
        RtdbPaths.resolve(SqliteTables.orderInventoryDeductions),
        'orderInventoryDeductions',
      );
    });

    test('every synced table has an explicit camelCase mapping', () {
      const List<String> syncedTables = <String>[
        SqliteTables.categories,
        SqliteTables.menuItems,
        SqliteTables.menuItemVariants,
        SqliteTables.menuItemOptions,
        SqliteTables.inventoryItems,
        SqliteTables.recipeIngredients,
        SqliteTables.stockMovements,
        SqliteTables.customers,
        SqliteTables.orders,
        SqliteTables.orderItems,
        SqliteTables.orderItemOptions,
        SqliteTables.payments,
        SqliteTables.refunds,
        SqliteTables.orderInventoryDeductions,
        SqliteTables.kotRecords,
        SqliteTables.kotItems,
        SqliteTables.kotItemOptions,
        SqliteTables.expenses,
      ];
      for (final String table in syncedTables) {
        expect(RtdbPaths.resolve(table), isNot(contains('_')));
      }
    });

    test('scopes records under restaurants/{uid}/{node}/{id}', () {
      expect(
        RtdbPaths.record('restaurant-abc', SqliteTables.menuItems, 'itm_1'),
        'restaurants/restaurant-abc/menuItems/itm_1',
      );
      expect(
        RtdbPaths.collection('restaurant-abc', SqliteTables.orders),
        'restaurants/restaurant-abc/orders',
      );
      expect(
        RtdbPaths.resolve(SqliteTables.expenses),
        'expenses',
      );
      expect(
        RtdbPaths.restaurantNode('restaurant-abc', RtdbPaths.managerPassword),
        'restaurants/restaurant-abc/managerPassword',
      );
    });
  });
}
