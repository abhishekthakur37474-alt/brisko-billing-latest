import '../../local/sqlite/sqlite_tables.dart';

/// Maps a local SQLite table name to the Realtime Database node used beneath
/// each restaurant.
///
/// The cloud tree is camelCase (`orderItems`, `menuItems`) so it stays readable
/// for any other client on the same project. Sync still speaks in local table
/// names; this is the only place that translation lives.
class RtdbPaths {
  const RtdbPaths._();

  static const Map<String, String> _byTable = <String, String>{
    SqliteTables.categories: 'categories',
    SqliteTables.menuItems: 'menuItems',
    SqliteTables.menuItemVariants: 'menuItemVariants',
    SqliteTables.menuItemOptions: 'menuItemOptions',
    SqliteTables.inventoryItems: 'inventoryItems',
    SqliteTables.recipeIngredients: 'recipeIngredients',
    SqliteTables.stockMovements: 'stockMovements',
    SqliteTables.customers: 'customers',
    SqliteTables.orders: 'orders',
    SqliteTables.orderItems: 'orderItems',
    SqliteTables.orderItemOptions: 'orderItemOptions',
    SqliteTables.payments: 'payments',
    SqliteTables.refunds: 'refunds',
    SqliteTables.orderInventoryDeductions: 'orderInventoryDeductions',
    SqliteTables.kotRecords: 'kotRecords',
    SqliteTables.kotItems: 'kotItems',
    SqliteTables.kotItemOptions: 'kotItemOptions',
  };

  /// Local table names that have a cloud node, in no particular order.
  static Iterable<String> get syncedTables => _byTable.keys;

  /// The RTDB node name for [table]. Falls back to the table name itself so an
  /// unmapped table still syncs somewhere sane rather than failing.
  static String resolve(String table) => _byTable[table] ?? table;

  /// `restaurants/{restaurantId}`
  static String restaurant(String restaurantId) =>
      'restaurants/$restaurantId';

  /// `restaurants/{restaurantId}/{node}`
  static String collection(String restaurantId, String table) =>
      '${restaurant(restaurantId)}/${resolve(table)}';

  /// `restaurants/{restaurantId}/{node}/{id}`
  static String record(String restaurantId, String table, String id) =>
      '${collection(restaurantId, table)}/$id';
}
