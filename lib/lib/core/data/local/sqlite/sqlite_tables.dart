/// Table and column names for the local SQLite database.
///
/// Centralised so that a rename is a compile error rather than a runtime "no such
/// column". Nothing outside `lib/core/data/local/sqlite/` and the feature `data/`
/// layers should reference these.
class SqliteTables {
  const SqliteTables._();

  static const String categories = 'categories';
  static const String menuItems = 'menu_items';
  static const String menuItemVariants = 'menu_item_variants';
  static const String menuItemOptions = 'menu_item_options';
  static const String orders = 'orders';
  static const String orderItems = 'order_items';
  static const String orderItemOptions = 'order_item_options';
  static const String payments = 'payments';

  /// Money handed back on a completed bill. A separate table from [payments] so the
  /// original tender is never rewritten; see `M008Refunds`.
  static const String refunds = 'refunds';
  static const String customers = 'customers';
  static const String inventoryItems = 'inventory_items';
  static const String stockMovements = 'stock_movements';
  static const String recipeIngredients = 'recipe_ingredients';
  static const String orderInventoryDeductions = 'order_inventory_deductions';
  static const String kotRecords = 'kot_records';
  static const String kotItems = 'kot_items';
  static const String kotItemOptions = 'kot_item_options';
  static const String heldBills = 'held_bills';
  static const String heldBillLines = 'held_bill_lines';
  static const String heldBillLineOptions = 'held_bill_line_options';
  static const String settings = 'settings';
  static const String expenses = 'expenses';
  static const String outbox = 'outbox';

  /// Cloud synchronisation bookmarks: the pull high-water mark, the last
  /// successful sync time, and the initial-bootstrap flag. See
  /// `M010CloudSyncMetadata`. Never holds bill data.
  static const String syncMetadata = 'sync_metadata';
}

/// Columns every syncable table carries.
///
/// These four exist because of the offline-first contract established in
/// `SyncableEntity`: a device-generated [id], an [updatedAt] conflict key, a
/// [syncState] recording cloud acknowledgement, and [isDeleted] so a deletion made
/// offline can still be transmitted.
class SyncColumns {
  const SyncColumns._();

  static const String id = 'id';
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
  static const String isDeleted = 'isDeleted';
  static const String syncState = 'syncState';

  /// Column fragment shared by every syncable table definition.
  ///
  /// Timestamps are stored as milliseconds since the Unix epoch in UTC, which
  /// sorts correctly as an integer and carries no timezone ambiguity.
  static const String definition =
      '''
    $id TEXT PRIMARY KEY NOT NULL,
    $createdAt INTEGER NOT NULL,
    $updatedAt INTEGER NOT NULL,
    $isDeleted INTEGER NOT NULL DEFAULT 0,
    $syncState TEXT NOT NULL DEFAULT 'pending'
  ''';
}
