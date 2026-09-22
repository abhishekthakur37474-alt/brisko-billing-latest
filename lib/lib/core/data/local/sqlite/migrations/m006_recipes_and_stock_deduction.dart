import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Connects what is sold to what is consumed, and records whether a bill's stock
/// has been taken off the shelf.
///
/// ## Why a migration is needed at all
///
/// Version 1 already holds `inventory_items` and `stock_movements`, and both are
/// reused unchanged: an item still carries its unit, its balance and its reorder
/// threshold, and every change to a balance still writes a ledger row. What version 1
/// has no way to express is the *relationship* between a menu item and the stock it
/// uses. There is no column anywhere that could say "a Medium Cheese Pizza uses 150 g
/// of flour", so the two tables added here are the smallest addition that makes
/// automatic deduction possible.
///
/// Nothing existing is altered and nothing is dropped. Every menu, order, payment and
/// kitchen row survives untouched.
///
/// ## Why recipes have no header table
///
/// A recipe is nothing but its ingredient lines, so it is stored as nothing but its
/// ingredient lines. `recipe_ingredients` carries the scope it belongs to on each row,
/// exactly the way `menu_item_options` already carries its scope, and "the recipe for
/// a Medium Cheese Pizza" is the set of rows matching that scope. A header table would
/// add a join and a row with no attributes of its own, and it would introduce a state
/// the outlet does not need: a recipe that exists but lists nothing. Here, no rows
/// means no recipe configured, which is precisely the fact the inventory screen has to
/// report.
///
/// ## Why the deduction ledger is a table rather than a flag on the order
///
/// Deducting stock happens *after* the money is committed, so it can fail on its own
/// — most obviously when the shelf does not hold what the recipe says it should. That
/// makes it a small workflow rather than a boolean: it has an attempt count, a reason
/// it failed, and a list of sold items that had no recipe to work from. A column on
/// `orders` could hold none of that, and putting it there would also mix a settled
/// financial record with a stock operation that may still be retried.
///
/// The unique index on `orderId` is what makes deduction idempotent. A second attempt
/// on a bill whose row already says `deducted` cannot insert a second row and cannot
/// deduct a second time.
class M006RecipesAndStockDeduction implements Migration {
  const M006RecipesAndStockDeduction();

  @override
  int get version => 6;

  @override
  String get description => 'Recipes and automatic stock deduction';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    // ------------------------------------------------------------- recipes ---
    // variantId is nullable, and the nullability is the design rather than a
    // convenience. A pizza's sizes each use a different amount of dough, so those
    // recipes are scoped to the variant. A burger has no sizes at all, so its recipe
    // is scoped to the product with variantId NULL. Both shapes live in this one
    // table, and the deduction reads the variant scope first and the product scope
    // only as a fallback, so an outlet can configure one recipe for every size and
    // then override a single size later without restructuring anything.
    //
    // quantityMilli is the amount for ONE sold unit, in thousandths of the stock
    // item's unit, matching inventory_items.currentQuantityMilli. Selling three
    // pizzas multiplies it by three; it is never divided, so no rounding arises.
    //
    // Both foreign keys are ON DELETE RESTRICT, in line with the rest of the schema:
    // deletion is soft everywhere, so a discontinued product keeps its recipe rows
    // and an already-settled bill can still be explained.
    '''
    CREATE TABLE ${SqliteTables.recipeIngredients} (
      ${SyncColumns.definition},
      menuItemId TEXT NOT NULL,
      variantId TEXT,
      inventoryItemId TEXT NOT NULL,
      quantityMilli INTEGER NOT NULL,
      FOREIGN KEY (menuItemId) REFERENCES ${SqliteTables.menuItems} (id)
        ON DELETE RESTRICT,
      FOREIGN KEY (variantId) REFERENCES ${SqliteTables.menuItemVariants} (id)
        ON DELETE RESTRICT,
      FOREIGN KEY (inventoryItemId) REFERENCES ${SqliteTables.inventoryItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    // The lookup deduction makes: every line for the products on a bill, in one
    // query.
    '''
    CREATE INDEX idx_recipe_ingredients_item
      ON ${SqliteTables.recipeIngredients} (menuItemId, variantId, isDeleted)
    ''',
    // Answers "which recipes use this stock item", which is what stops an item being
    // deleted while something still consumes it.
    '''
    CREATE INDEX idx_recipe_ingredients_stock
      ON ${SqliteTables.recipeIngredients} (inventoryItemId, isDeleted)
    ''',

    // Two partial unique indexes rather than one plain one, because SQLite treats
    // NULLs as distinct in a unique index: UNIQUE (menuItemId, variantId,
    // inventoryItemId) would happily allow flour twice on a product-level recipe,
    // since variantId is NULL both times and NULL never equals NULL. Splitting the
    // constraint by whether the row is variant-scoped makes both cases enforceable,
    // and excluding soft-deleted rows means an ingredient can be removed and added
    // back later.
    '''
    CREATE UNIQUE INDEX idx_recipe_ingredients_unique_variant
      ON ${SqliteTables.recipeIngredients} (variantId, inventoryItemId)
      WHERE variantId IS NOT NULL AND isDeleted = 0
    ''',
    '''
    CREATE UNIQUE INDEX idx_recipe_ingredients_unique_product
      ON ${SqliteTables.recipeIngredients} (menuItemId, inventoryItemId)
      WHERE variantId IS NULL AND isDeleted = 0
    ''',

    // --------------------------------------------------- deduction ledger ---
    // orderNumberSnapshot is a copy, like every other snapshot in this schema. The
    // admin list of bills whose stock could not be taken off has to name them, and
    // naming them by joining the orders table would make this record depend on a
    // table it is only loosely about.
    //
    // unconfiguredItems holds the newline-separated display names of the sold lines
    // that had no recipe, as they appeared on the bill. It is a report of what the
    // operator still has to configure, snapshotted at the moment the bill was
    // processed, not a relation — which is why it is one text column rather than a
    // child table.
    '''
    CREATE TABLE ${SqliteTables.orderInventoryDeductions} (
      ${SyncColumns.definition},
      orderId TEXT NOT NULL,
      orderNumberSnapshot TEXT NOT NULL,
      status TEXT NOT NULL,
      attemptCount INTEGER NOT NULL DEFAULT 0,
      movementCount INTEGER NOT NULL DEFAULT 0,
      unconfiguredCount INTEGER NOT NULL DEFAULT 0,
      unconfiguredItems TEXT,
      failureMessage TEXT,
      FOREIGN KEY (orderId) REFERENCES ${SqliteTables.orders} (id)
        ON DELETE RESTRICT
    )
    ''',
    // The idempotency key. One bill can only ever have one deduction record, so a
    // retry updates that row instead of deducting again.
    '''
    CREATE UNIQUE INDEX idx_order_inventory_deductions_order
      ON ${SqliteTables.orderInventoryDeductions} (orderId)
    ''',
    // Drives the admin list of bills that still need attention.
    '''
    CREATE INDEX idx_order_inventory_deductions_status
      ON ${SqliteTables.orderInventoryDeductions} (status, createdAt)
    ''',

    // ------------------------------------------------------ normalisations ---
    // Both updates below are defensive rather than corrective. Nothing has ever
    // seeded `inventory_items`, and until this version the inventory screen was a
    // placeholder with no way to create a row, so on every real terminal these two
    // statements match nothing. They are here so that a database which somehow does
    // hold a row is read correctly rather than silently misinterpreted.

    // The unit is now a known set rather than free text, stored by its Dart name.
    // Anything already stored as a symbol is mapped onto the matching name; an
    // unrecognised value is left exactly as it was rather than guessed at.
    '''
    UPDATE ${SqliteTables.inventoryItems}
    SET unit = CASE lower(trim(unit))
      WHEN 'g' THEN 'gram'
      WHEN 'gm' THEN 'gram'
      WHEN 'gms' THEN 'gram'
      WHEN 'gram' THEN 'gram'
      WHEN 'grams' THEN 'gram'
      WHEN 'kg' THEN 'kilogram'
      WHEN 'kgs' THEN 'kilogram'
      WHEN 'kilogram' THEN 'kilogram'
      WHEN 'kilograms' THEN 'kilogram'
      WHEN 'ml' THEN 'millilitre'
      WHEN 'millilitre' THEN 'millilitre'
      WHEN 'milliliter' THEN 'millilitre'
      WHEN 'l' THEN 'litre'
      WHEN 'ltr' THEN 'litre'
      WHEN 'litre' THEN 'litre'
      WHEN 'liter' THEN 'litre'
      WHEN 'pc' THEN 'piece'
      WHEN 'pcs' THEN 'piece'
      WHEN 'piece' THEN 'piece'
      WHEN 'pieces' THEN 'piece'
      ELSE unit
    END
    ''',

    // `purchase` has become `stockIn`. The outlet receives stock; it does not run
    // procurement, and purchase orders are explicitly not part of this product. The
    // stored token follows the renamed enum value so the ledger reads the same way
    // the screens do.
    '''
    UPDATE ${SqliteTables.stockMovements}
    SET movementType = 'stockIn'
    WHERE movementType = 'purchase'
    ''',
  ];
}
