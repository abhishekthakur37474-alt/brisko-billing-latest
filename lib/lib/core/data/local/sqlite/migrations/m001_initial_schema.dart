import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Creates the initial schema for a single-outlet, single-terminal POS.
///
/// Conventions used throughout:
///
/// * Primary keys are `TEXT` holding device-generated ids from `EntityId`, not
///   SQLite `AUTOINCREMENT`. An offline bill must own its final identity at the
///   moment it is created.
/// * Money is `INTEGER` paise in columns suffixed `Paise`. See `Money`.
/// * Quantities that can be fractional are `INTEGER` thousandths in columns
///   suffixed `Milli`, for the same determinism reason as money. Countable
///   quantities, such as three pizzas, are plain `INTEGER`.
/// * Timestamps are `INTEGER` milliseconds since the Unix epoch, UTC.
/// * Booleans are `INTEGER` 0 or 1.
/// * Enums are stored as their Dart name in `TEXT`, which keeps the database
///   readable and survives reordering of the enum declaration.
/// * Deletion is soft, via `isDeleted`. Foreign keys therefore use
///   `ON DELETE RESTRICT`; rows are not physically removed in normal operation.
class M001InitialSchema implements Migration {
  const M001InitialSchema();

  @override
  int get version => 1;

  @override
  String get description => 'Initial POS schema';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    // ---------------------------------------------------------------- menu ---
    '''
    CREATE TABLE ${SqliteTables.categories} (
      ${SyncColumns.definition},
      name TEXT NOT NULL,
      displayOrder INTEGER NOT NULL DEFAULT 0,
      isActive INTEGER NOT NULL DEFAULT 1
    )
    ''',
    '''
    CREATE INDEX idx_categories_order
      ON ${SqliteTables.categories} (isDeleted, isActive, displayOrder)
    ''',

    '''
    CREATE TABLE ${SqliteTables.menuItems} (
      ${SyncColumns.definition},
      categoryId TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      itemType TEXT NOT NULL,
      basePricePaise INTEGER NOT NULL,
      isAvailable INTEGER NOT NULL DEFAULT 1,
      isActive INTEGER NOT NULL DEFAULT 1,
      displayOrder INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (categoryId) REFERENCES ${SqliteTables.categories} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_menu_items_category
      ON ${SqliteTables.menuItems} (categoryId, isDeleted, isActive, displayOrder)
    ''',

    // A pizza sold in Small, Medium and Large has one row here per size. Items
    // with a single price have no variant rows at all and use basePricePaise.
    '''
    CREATE TABLE ${SqliteTables.menuItemVariants} (
      ${SyncColumns.definition},
      menuItemId TEXT NOT NULL,
      name TEXT NOT NULL,
      pricePaise INTEGER NOT NULL,
      displayOrder INTEGER NOT NULL DEFAULT 0,
      isActive INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (menuItemId) REFERENCES ${SqliteTables.menuItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_variants_item
      ON ${SqliteTables.menuItemVariants} (menuItemId, isDeleted, isActive, displayOrder)
    ''',

    // menuItemId is nullable on purpose: 'Extra Cheese' applies to every pizza,
    // so it is stored once with a NULL menuItemId rather than duplicated per item.
    // A non-NULL menuItemId scopes the option to that single item.
    '''
    CREATE TABLE ${SqliteTables.menuItemOptions} (
      ${SyncColumns.definition},
      menuItemId TEXT,
      name TEXT NOT NULL,
      optionType TEXT NOT NULL,
      pricePaise INTEGER NOT NULL,
      displayOrder INTEGER NOT NULL DEFAULT 0,
      isActive INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (menuItemId) REFERENCES ${SqliteTables.menuItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_options_item
      ON ${SqliteTables.menuItemOptions} (menuItemId, isDeleted, isActive, displayOrder)
    ''',

    // ----------------------------------------------------------- customers ---
    '''
    CREATE TABLE ${SqliteTables.customers} (
      ${SyncColumns.definition},
      name TEXT,
      phone TEXT NOT NULL
    )
    ''',
    // Phone is the lookup key at the counter, so it is indexed. Deliberately not
    // UNIQUE: the same number can legitimately arrive twice through a race or a
    // correction, and a hard constraint failure mid-bill is worse than a
    // duplicate the operator can merge later.
    '''
    CREATE INDEX idx_customers_phone
      ON ${SqliteTables.customers} (phone, isDeleted)
    ''',

    // -------------------------------------------------------------- orders ---
    // No tableId column. Dine-in is supported, but the outlet does not use digital
    // table or floor management, so there is nothing to reference.
    '''
    CREATE TABLE ${SqliteTables.orders} (
      ${SyncColumns.definition},
      orderNumber TEXT NOT NULL,
      orderType TEXT NOT NULL,
      status TEXT NOT NULL,
      customerId TEXT,
      subtotalPaise INTEGER NOT NULL DEFAULT 0,
      discountAmountPaise INTEGER NOT NULL DEFAULT 0,
      taxAmountPaise INTEGER NOT NULL DEFAULT 0,
      totalAmountPaise INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      FOREIGN KEY (customerId) REFERENCES ${SqliteTables.customers} (id)
        ON DELETE RESTRICT
    )
    ''',
    // One terminal issues order numbers, so they are unique by construction.
    '''
    CREATE UNIQUE INDEX idx_orders_number
      ON ${SqliteTables.orders} (orderNumber)
    ''',
    '''
    CREATE INDEX idx_orders_created
      ON ${SqliteTables.orders} (createdAt, isDeleted)
    ''',
    '''
    CREATE INDEX idx_orders_status
      ON ${SqliteTables.orders} (status, isDeleted)
    ''',
    // Drives customer order history without duplicating totals onto the customer.
    '''
    CREATE INDEX idx_orders_customer
      ON ${SqliteTables.orders} (customerId, createdAt)
    ''',

    // itemNameSnapshot, variantNameSnapshot and unitPricePaise are copies taken at
    // the moment of sale, not lookups. Re-pricing the menu next week must not
    // change what last week's bill says, and a reprint must reproduce the original
    // document exactly. Nothing reads historical bill values from the menu tables.
    '''
    CREATE TABLE ${SqliteTables.orderItems} (
      ${SyncColumns.definition},
      orderId TEXT NOT NULL,
      menuItemId TEXT,
      variantId TEXT,
      itemNameSnapshot TEXT NOT NULL,
      variantNameSnapshot TEXT,
      quantity INTEGER NOT NULL,
      unitPricePaise INTEGER NOT NULL,
      discountAmountPaise INTEGER NOT NULL DEFAULT 0,
      taxAmountPaise INTEGER NOT NULL DEFAULT 0,
      totalAmountPaise INTEGER NOT NULL,
      notes TEXT,
      FOREIGN KEY (orderId) REFERENCES ${SqliteTables.orders} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_order_items_order
      ON ${SqliteTables.orderItems} (orderId, isDeleted)
    ''',
    // Supports item-wise sales reporting later without joining through the menu.
    '''
    CREATE INDEX idx_order_items_menu_item
      ON ${SqliteTables.orderItems} (menuItemId, createdAt)
    ''',

    '''
    CREATE TABLE ${SqliteTables.orderItemOptions} (
      ${SyncColumns.definition},
      orderItemId TEXT NOT NULL,
      optionId TEXT,
      optionNameSnapshot TEXT NOT NULL,
      pricePaise INTEGER NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (orderItemId) REFERENCES ${SqliteTables.orderItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_order_item_options_item
      ON ${SqliteTables.orderItemOptions} (orderItemId, isDeleted)
    ''',

    // ------------------------------------------------------------ payments ---
    // Many-to-one against orders rather than payment columns on the order itself.
    // That is what makes split payment (part cash, part UPI) a matter of inserting
    // a second row later, with no schema change.
    '''
    CREATE TABLE ${SqliteTables.payments} (
      ${SyncColumns.definition},
      orderId TEXT NOT NULL,
      paymentMethod TEXT NOT NULL,
      amountPaise INTEGER NOT NULL,
      reference TEXT,
      status TEXT NOT NULL,
      FOREIGN KEY (orderId) REFERENCES ${SqliteTables.orders} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_payments_order
      ON ${SqliteTables.payments} (orderId, isDeleted)
    ''',
    '''
    CREATE INDEX idx_payments_method
      ON ${SqliteTables.payments} (paymentMethod, createdAt)
    ''',

    // ----------------------------------------------------------- inventory ---
    '''
    CREATE TABLE ${SqliteTables.inventoryItems} (
      ${SyncColumns.definition},
      name TEXT NOT NULL,
      unit TEXT NOT NULL,
      currentQuantityMilli INTEGER NOT NULL DEFAULT 0,
      minimumQuantityMilli INTEGER NOT NULL DEFAULT 0,
      isActive INTEGER NOT NULL DEFAULT 1
    )
    ''',
    '''
    CREATE INDEX idx_inventory_items_name
      ON ${SqliteTables.inventoryItems} (name, isDeleted, isActive)
    ''',

    // referenceId is an untyped link to whatever caused the movement, usually an
    // order id for a sale. It has no foreign key because a movement can also
    // originate from a purchase or a manual count that references nothing.
    '''
    CREATE TABLE ${SqliteTables.stockMovements} (
      ${SyncColumns.definition},
      inventoryItemId TEXT NOT NULL,
      movementType TEXT NOT NULL,
      quantityMilli INTEGER NOT NULL,
      reason TEXT,
      referenceId TEXT,
      FOREIGN KEY (inventoryItemId) REFERENCES ${SqliteTables.inventoryItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_stock_movements_item
      ON ${SqliteTables.stockMovements} (inventoryItemId, createdAt)
    ''',
    '''
    CREATE INDEX idx_stock_movements_reference
      ON ${SqliteTables.stockMovements} (referenceId)
    ''',

    // ----------------------------------------------------------------- KOT ---
    // The kitchen has no printer and no screen of its own. It receives a paper slip
    // produced by the same thermal printer as the customer bill. These tables record
    // what was sent to the kitchen and whether it has been printed; the printing
    // itself is a later step.
    '''
    CREATE TABLE ${SqliteTables.kotRecords} (
      ${SyncColumns.definition},
      orderId TEXT NOT NULL,
      kotNumber TEXT NOT NULL,
      status TEXT NOT NULL,
      FOREIGN KEY (orderId) REFERENCES ${SqliteTables.orders} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE UNIQUE INDEX idx_kot_records_number
      ON ${SqliteTables.kotRecords} (kotNumber)
    ''',
    '''
    CREATE INDEX idx_kot_records_order
      ON ${SqliteTables.kotRecords} (orderId, isDeleted)
    ''',

    '''
    CREATE TABLE ${SqliteTables.kotItems} (
      ${SyncColumns.definition},
      kotId TEXT NOT NULL,
      orderItemId TEXT NOT NULL,
      itemNameSnapshot TEXT NOT NULL,
      variantNameSnapshot TEXT,
      quantity INTEGER NOT NULL,
      notes TEXT,
      FOREIGN KEY (kotId) REFERENCES ${SqliteTables.kotRecords} (id)
        ON DELETE RESTRICT,
      FOREIGN KEY (orderItemId) REFERENCES ${SqliteTables.orderItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_kot_items_kot
      ON ${SqliteTables.kotItems} (kotId, isDeleted)
    ''',

    // ------------------------------------------------------------ settings ---
    // Key/value rather than a one-row table with a column per setting, so adding
    // "receipt footer" later needs no migration. Values are stored as text and
    // interpreted by the settings repository.
    '''
    CREATE TABLE ${SqliteTables.settings} (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT,
      updatedAt INTEGER NOT NULL
    )
    ''',

    // -------------------------------------------------------------- outbox ---
    // Durable queue backing the existing OutboxStore contract. Present from
    // version 1 so that every write made before a backend exists is already
    // recorded, and enabling synchronisation later needs no data backfill.
    '''
    CREATE TABLE ${SqliteTables.outbox} (
      id TEXT PRIMARY KEY NOT NULL,
      collection TEXT NOT NULL,
      entityId TEXT NOT NULL,
      operation TEXT NOT NULL,
      payload TEXT NOT NULL,
      queuedAt INTEGER NOT NULL,
      attemptCount INTEGER NOT NULL DEFAULT 0,
      lastError TEXT
    )
    ''',
    // Replay order is queue order, oldest first.
    '''
    CREATE INDEX idx_outbox_queued
      ON ${SqliteTables.outbox} (queuedAt)
    ''',
  ];
}
