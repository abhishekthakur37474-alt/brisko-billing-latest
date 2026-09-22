import '../../core/data/local/sqlite/sqlite_database.dart';
import '../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../core/data/local/sqlite/sqlite_outbox_store.dart';
import '../../core/data/local/sqlite/sqlite_tables.dart';
import '../../core/data/remote/remote_store_factory.dart';
import '../../core/data/sync/sync_endpoint.dart';
import '../../core/data/sync/syncable_entity.dart';
import '../../features/customers/domain/models/customer.dart';
import '../../features/expenses/domain/models/expense.dart';
import '../../features/inventory/domain/models/inventory_item.dart';
import '../../features/inventory/domain/models/order_inventory_deduction.dart';
import '../../features/inventory/domain/models/recipe_ingredient.dart';
import '../../features/inventory/domain/models/stock_movement.dart';
import '../../features/kot/domain/models/kot_item.dart';
import '../../features/kot/domain/models/kot_item_option.dart';
import '../../features/kot/domain/models/kot_record.dart';
import '../../features/menu/domain/models/menu_category.dart';
import '../../features/menu/domain/models/menu_item.dart';
import '../../features/menu/domain/models/menu_item_option.dart';
import '../../features/menu/domain/models/menu_item_variant.dart';
import '../../features/orders/domain/models/order.dart';
import '../../features/orders/domain/models/order_item.dart';
import '../../features/orders/domain/models/order_item_option.dart';
import '../../features/payments/domain/models/payment.dart';
import '../../features/payments/domain/models/refund.dart';

/// The single, ordered list of collections the terminal synchronises with the
/// cloud, built at the composition root.
///
/// ## What is here, and what is deliberately not
///
/// Every entity that makes up the outlet's durable record is here: the menu and
/// its variants and options, inventory and its recipes and movements, customers,
/// expenses, and the whole of a settled sale — order, lines, options, payments,
/// refunds, deductions and kitchen slips. That is the data a reinstalled or
/// replaced terminal must get back.
///
/// Held bills are absent on purpose. A bill parked at the counter is transient
/// working state, not a committed sale; it has no order number, no payment and no
/// kitchen slip, and it is discarded or settled within the shift. Printer state,
/// print jobs and other device-local concerns are absent for the same reason: they
/// belong to this machine, not to the outlet's record. Settings are configuration,
/// not transactional data, and are left to the operator to set per terminal.
/// The manager password is also absent here: it is a singleton RTDB node written
/// directly, not an outbox collection.
///
/// ## Order matters
///
/// The list is in dependency order — a parent before anything that references it —
/// because the local database enforces foreign keys. A pull applies each collection
/// in this order, so an order is on disk before its lines are, and a menu item
/// before the variants that point at it. Reordering this list can make a restore
/// fail on a foreign-key constraint, so it is not arbitrary.
List<SyncEndpointBase> buildSyncEndpoints(
  SqliteDatabase database,
  RemoteStoreFactory remoteFactory,
  SqliteOutboxStore outbox,
) {
  SyncEndpoint<T> endpoint<T extends SyncableEntity>(
    String table,
    T Function(Map<String, Object?> row) fromRow,
  ) {
    return SyncEndpoint<T>(
      collection: table,
      fromRow: fromRow,
      local: SqliteLocalStore<T>(
        database: database,
        table: table,
        fromRow: fromRow,
        outbox: outbox,
      ),
      remote: remoteFactory.create<T>(table, fromRow),
    );
  }

  return <SyncEndpointBase>[
    // Reference data first: the menu and the store cupboard nothing else can be
    // pulled without.
    endpoint<MenuCategory>(SqliteTables.categories, MenuCategory.fromRow),
    endpoint<MenuItem>(SqliteTables.menuItems, MenuItem.fromRow),
    endpoint<MenuItemVariant>(
      SqliteTables.menuItemVariants,
      MenuItemVariant.fromRow,
    ),
    endpoint<MenuItemOption>(
      SqliteTables.menuItemOptions,
      MenuItemOption.fromRow,
    ),
    endpoint<InventoryItem>(SqliteTables.inventoryItems, InventoryItem.fromRow),
    endpoint<RecipeIngredient>(
      SqliteTables.recipeIngredients,
      RecipeIngredient.fromRow,
    ),
    endpoint<Customer>(SqliteTables.customers, Customer.fromRow),

    // Then the settled sale, header before the rows that hang off it.
    endpoint<Order>(SqliteTables.orders, Order.fromRow),
    endpoint<OrderItem>(SqliteTables.orderItems, OrderItem.fromRow),
    endpoint<OrderItemOption>(
      SqliteTables.orderItemOptions,
      OrderItemOption.fromRow,
    ),
    endpoint<Payment>(SqliteTables.payments, Payment.fromRow),
    endpoint<Refund>(SqliteTables.refunds, Refund.fromRow),
    endpoint<StockMovement>(SqliteTables.stockMovements, StockMovement.fromRow),
    endpoint<OrderInventoryDeduction>(
      SqliteTables.orderInventoryDeductions,
      OrderInventoryDeduction.fromRow,
    ),
    endpoint<KotRecord>(SqliteTables.kotRecords, KotRecord.fromRow),
    endpoint<KotItem>(SqliteTables.kotItems, KotItem.fromRow),
    endpoint<KotItemOption>(SqliteTables.kotItemOptions, KotItemOption.fromRow),
    endpoint<Expense>(SqliteTables.expenses, Expense.fromRow),
  ];
}

/// The tables that mean a terminal is already in use, as opposed to a fresh
/// install that merely has the seeded menu.
///
/// Used by the initial bootstrap to decide whether a restore is safe: if any of
/// these holds a row, the terminal has taken real work and the cloud must never be
/// pulled over it. The seeded reference tables are deliberately excluded, because
/// they are present on every fresh install.
const List<String> operationalTables = <String>[
  SqliteTables.orders,
  SqliteTables.orderItems,
  SqliteTables.payments,
  SqliteTables.refunds,
  SqliteTables.customers,
  SqliteTables.stockMovements,
  SqliteTables.kotRecords,
  SqliteTables.orderInventoryDeductions,
  SqliteTables.expenses,
];
