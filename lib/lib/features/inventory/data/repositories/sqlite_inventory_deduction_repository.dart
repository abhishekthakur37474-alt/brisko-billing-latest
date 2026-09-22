import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/inventory_deduction_status.dart';
import '../../domain/models/order_inventory_deduction.dart';
import '../../domain/models/recipe_ingredient.dart';
import '../../domain/models/recipe_scope.dart';
import '../../domain/models/stock_movement.dart';
import '../../domain/models/stock_movement_type.dart';
import '../../domain/models/stock_quantity.dart';
import '../../domain/models/stock_unit.dart';
import '../../domain/repositories/inventory_deduction_repository.dart';
import '../stock_ledger.dart';

/// SQLite implementation of [InventoryDeductionRepository].
///
/// ## The shape of the operation
///
/// One transaction does the whole deduction: it re-checks that the bill has not
/// already been processed, resolves the recipes, verifies every shelf, writes the
/// movements, applies the balances, and marks the bill done. Any refusal thrown inside
/// it takes all of that with it, so a bill is either fully deducted or untouched.
///
/// A refusal then needs recording, and it cannot be recorded in the transaction that
/// just rolled back. So the failure row is written afterwards, in its own small
/// transaction. That is the only reason there are two writes rather than one, and it is
/// what makes "nothing was deducted, and here is why" a durable statement rather than a
/// message that disappears with the screen.
class SqliteInventoryDeductionRepository
    implements InventoryDeductionRepository {
  SqliteInventoryDeductionRepository({required this._database});

  /// Tables a deduction touches. Watchers on all of them are woken once it commits.
  static const List<String> _tables = <String>[
    ...StockLedger.tables,
    SqliteTables.orderInventoryDeductions,
  ];

  final SqliteDatabase _database;

  Database get _db => _database.database;

  @override
  Future<Result<OrderInventoryDeduction>> deductForOrder(String orderId) async {
    final Result<OrderInventoryDeduction> result =
        await SqliteErrorMapper.guard<OrderInventoryDeduction>(
          () => _deduct(orderId),
          context: 'update the stock for this bill',
        );

    final AppFailure? failure = result.failureOrNull;
    if (failure == null) {
      _database.notifyTablesChanged(_tables);
      return result;
    }

    // The attempt rolled back, so nothing was deducted. Record that fact where an
    // operator can find it. Best effort on purpose: if even this cannot be written —
    // for instance because the bill does not exist, so there is nothing to attach it
    // to — the caller still gets the original failure, which is the more useful one.
    await _recordFailure(orderId, failure.message);
    _database.notifyTableChanged(SqliteTables.orderInventoryDeductions);

    return result;
  }

  @override
  Future<Result<OrderInventoryDeduction?>> findDeduction(String orderId) {
    return SqliteErrorMapper.guard<OrderInventoryDeduction?>(
      () => _findRecord(_db, orderId),
      context: 'load the stock deduction for this bill',
    );
  }

  @override
  Future<Result<List<OrderInventoryDeduction>>> loadFailedDeductions({
    int limit = 50,
  }) {
    return SqliteErrorMapper.guard<List<OrderInventoryDeduction>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orderInventoryDeductions,
        where: 'status = ? AND isDeleted = 0',
        whereArgs: <Object?>[InventoryDeductionStatus.failed.name],
        orderBy: 'createdAt DESC, rowid DESC',
        limit: limit,
      );
      return rows.map(OrderInventoryDeduction.fromRow).toList(growable: false);
    }, context: 'load the bills whose stock was not deducted');
  }

  @override
  Future<Result<List<OrderInventoryDeduction>>> loadUnconfiguredDeductions({
    int limit = 50,
  }) {
    return SqliteErrorMapper.guard<List<OrderInventoryDeduction>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.orderInventoryDeductions,
        where: 'unconfiguredCount > 0 AND isDeleted = 0',
        orderBy: 'createdAt DESC, rowid DESC',
        limit: limit,
      );
      return rows.map(OrderInventoryDeduction.fromRow).toList(growable: false);
    }, context: 'load the bills with items that have no recipe');
  }

  // --------------------------------------------------------------- the attempt ---

  Future<OrderInventoryDeduction> _deduct(String orderId) async {
    // Checked before opening a transaction so the overwhelmingly common retry — a
    // bill that is already done — costs one indexed read and takes no write lock.
    final OrderInventoryDeduction? settled = await _findRecord(_db, orderId);
    if (settled != null && settled.isComplete) {
      return settled;
    }

    late OrderInventoryDeduction written;

    await _db.transaction((Transaction txn) async {
      // Read again inside the transaction. Between the check above and here another
      // attempt could have completed, and deducting twice is the one outcome this
      // whole class exists to prevent.
      final OrderInventoryDeduction? existing = await _findRecord(txn, orderId);
      if (existing != null && existing.isComplete) {
        written = existing;
        return;
      }

      final _SettledBill bill = await _requireBill(txn, orderId);
      final List<_SoldLine> lines = await _soldLines(txn, orderId);
      final _Requirements requirements = await _resolve(txn, lines);

      final List<StockMovement> movements = await _movementsFor(
        txn,
        orderId: orderId,
        requirements: requirements,
        at: bill.at,
      );

      // Each balance and its ledger row are written together, and all of them inside
      // this one transaction, so the bill's deduction is a single event.
      for (final StockMovement movement in movements) {
        await StockLedger.record(
          txn,
          movement: movement,
          at: movement.createdAt,
        );
      }

      written = OrderInventoryDeduction(
        // The row's own identity is kept across a retry. A new id each attempt would
        // make one stock operation look like several to anything reading the table.
        id: existing?.id ?? EntityId.generate(prefix: 'sdd'),
        orderId: orderId,
        orderNumberSnapshot: bill.orderNumber,
        status: InventoryDeductionStatus.deducted,
        attemptCount: (existing?.attemptCount ?? 0) + 1,
        movementCount: movements.length,
        unconfiguredItems: requirements.unconfiguredItems,
        createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      await SqliteUpsert.run(
        txn,
        SqliteTables.orderInventoryDeductions,
        written.toMap(),
      );
    });

    return written;
  }

  /// Records that nothing was deducted, and why.
  ///
  /// Its own transaction, because the attempt's transaction has already rolled back.
  /// Never throws: this is reporting, and a failure to report must not replace the
  /// failure being reported.
  Future<void> _recordFailure(String orderId, String message) async {
    await SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        final OrderInventoryDeduction? existing = await _findRecord(
          txn,
          orderId,
        );
        if (existing != null && existing.isComplete) {
          // Completed by a concurrent attempt while this one was failing. The stock
          // is off the shelf; overwriting the record with a failure would be a lie.
          return;
        }

        final List<Map<String, Object?>> order = await txn.query(
          SqliteTables.orders,
          columns: <String>['orderNumber'],
          where: 'id = ?',
          whereArgs: <Object?>[orderId],
          limit: 1,
        );
        if (order.isEmpty) {
          // No such bill. There is nothing for a deduction row to reference, and the
          // foreign key would refuse it anyway.
          return;
        }

        final DateTime now = DateTime.now().toUtc();
        final OrderInventoryDeduction record = OrderInventoryDeduction(
          id: existing?.id ?? EntityId.generate(prefix: 'sdd'),
          orderId: orderId,
          orderNumberSnapshot: order.first['orderNumber']! as String,
          status: InventoryDeductionStatus.failed,
          attemptCount: (existing?.attemptCount ?? 0) + 1,
          // Nothing was deducted, so nothing is claimed. Any count from an earlier
          // attempt is deliberately not carried forward.
          unconfiguredItems: existing?.unconfiguredItems ?? const <String>[],
          failureMessage: message,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        );

        await SqliteUpsert.run(
          txn,
          SqliteTables.orderInventoryDeductions,
          record.toMap(),
        );
      });
    }, context: 'record the failed stock deduction');
  }

  // ------------------------------------------------------------------- reading ---

  static Future<OrderInventoryDeduction?> _findRecord(
    DatabaseExecutor db,
    String orderId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.orderInventoryDeductions,
      where: 'orderId = ? AND isDeleted = 0',
      whereArgs: <Object?>[orderId],
      limit: 1,
    );
    return rows.isEmpty ? null : OrderInventoryDeduction.fromRow(rows.first);
  }

  /// The settled bill, or a refusal.
  static Future<_SettledBill> _requireBill(
    DatabaseExecutor db,
    String orderId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.orders,
      columns: <String>['orderNumber', 'createdAt'],
      where: 'id = ? AND isDeleted = 0',
      whereArgs: <Object?>[orderId],
      limit: 1,
    );

    if (rows.isEmpty) {
      throw ArgumentError.value(
        orderId,
        'orderId',
        'That bill has not been settled, so there is nothing to deduct',
      );
    }

    return _SettledBill(
      orderNumber: rows.first['orderNumber']! as String,
      at: DateTime.fromMillisecondsSinceEpoch(
        rows.first['createdAt']! as int,
        isUtc: true,
      ),
    );
  }

  /// The bill's lines, exactly as they were persisted.
  ///
  /// Reads the snapshot columns and the two reporting back-references, and nothing
  /// from the menu. `itemNameSnapshot` is what an unconfigured line is reported as, so
  /// even that name is the one the customer was charged for rather than whatever the
  /// product is called now.
  static Future<List<_SoldLine>> _soldLines(
    DatabaseExecutor db,
    String orderId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.orderItems,
      columns: <String>[
        'menuItemId',
        'variantId',
        'itemNameSnapshot',
        'variantNameSnapshot',
        'quantity',
      ],
      where: 'orderId = ? AND isDeleted = 0',
      whereArgs: <Object?>[orderId],
      orderBy: 'createdAt ASC, rowid ASC',
    );

    return rows
        .map(
          (Map<String, Object?> row) => _SoldLine(
            menuItemId: row['menuItemId'] as String?,
            variantId: row['variantId'] as String?,
            displayName: _displayName(row),
            quantity: row['quantity']! as int,
          ),
        )
        .toList(growable: false);
  }

  static String _displayName(Map<String, Object?> row) {
    final String name = row['itemNameSnapshot']! as String;
    final String? variant = row['variantNameSnapshot'] as String?;
    return variant == null ? name : '$name ($variant)';
  }

  // ------------------------------------------------------------------ resolving ---

  /// Turns the bill's lines into one total per stock item.
  ///
  /// Recipe rows for every product on the bill are fetched in one query and grouped by
  /// scope in Dart, rather than queried per line. A bill with three sizes of the same
  /// pizza would otherwise issue three near-identical reads, and the grouping is what
  /// makes the variant-then-product fallback a lookup rather than a second query.
  static Future<_Requirements> _resolve(
    DatabaseExecutor db,
    List<_SoldLine> lines,
  ) async {
    final Set<String> menuItemIds = lines
        .map((_SoldLine line) => line.menuItemId)
        .whereType<String>()
        .toSet();

    final Map<RecipeScope, List<RecipeIngredient>> byScope =
        await _ingredientsByScope(db, menuItemIds);

    final Map<String, int> totals = <String, int>{};
    final List<String> unconfigured = <String>[];

    for (final _SoldLine line in lines) {
      final List<RecipeIngredient>? recipe = _recipeFor(line, byScope);

      if (recipe == null) {
        // No recipe, so nothing is deducted and nothing is invented. The line is
        // named for the operator instead.
        if (!unconfigured.contains(line.displayName)) {
          unconfigured.add(line.displayName);
        }
        continue;
      }

      for (final RecipeIngredient ingredient in recipe) {
        // Aggregated across the whole bill: two lines of pizza that both use cheese
        // come off the same shelf once, so one movement records the total rather than
        // two racing to update the same balance.
        totals[ingredient.inventoryItemId] =
            (totals[ingredient.inventoryItemId] ?? StockQuantity.zero) +
            ingredient.requiredFor(line.quantity);
      }
    }

    return _Requirements(totals: totals, unconfiguredItems: unconfigured);
  }

  /// The recipe a line consumes, or `null` when it has none.
  ///
  /// The size's own recipe wins; the product's is the fallback. That order lets an
  /// outlet write one recipe covering every size and later override a single size
  /// without touching the others.
  static List<RecipeIngredient>? _recipeFor(
    _SoldLine line,
    Map<RecipeScope, List<RecipeIngredient>> byScope,
  ) {
    final String? menuItemId = line.menuItemId;
    if (menuItemId == null) {
      // The line kept no product reference, so there is nothing to look a recipe up
      // by. Reported as unconfigured rather than guessed at from its name.
      return null;
    }

    final String? variantId = line.variantId;
    if (variantId != null) {
      final List<RecipeIngredient>? forVariant =
          byScope[RecipeScope.variant(
            menuItemId: menuItemId,
            variantId: variantId,
          )];
      if (forVariant != null && forVariant.isNotEmpty) {
        return forVariant;
      }
    }

    final List<RecipeIngredient>? forProduct =
        byScope[RecipeScope.product(menuItemId)];
    return forProduct == null || forProduct.isEmpty ? null : forProduct;
  }

  static Future<Map<RecipeScope, List<RecipeIngredient>>> _ingredientsByScope(
    DatabaseExecutor db,
    Set<String> menuItemIds,
  ) async {
    if (menuItemIds.isEmpty) {
      return const <RecipeScope, List<RecipeIngredient>>{};
    }

    final String placeholders = List<String>.filled(
      menuItemIds.length,
      '?',
    ).join(', ');

    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.recipeIngredients,
      where: 'menuItemId IN ($placeholders) AND isDeleted = 0',
      whereArgs: menuItemIds.toList(growable: false),
    );

    final Map<RecipeScope, List<RecipeIngredient>> byScope =
        <RecipeScope, List<RecipeIngredient>>{};

    for (final Map<String, Object?> row in rows) {
      final RecipeIngredient ingredient = RecipeIngredient.fromRow(row);
      byScope
          .putIfAbsent(ingredient.scope, () => <RecipeIngredient>[])
          .add(ingredient);
    }
    return byScope;
  }

  // ------------------------------------------------------------------- writing ---

  /// One movement per stock item, after checking that every shelf can cover it.
  ///
  /// The shelves are all verified before the first movement is written. The balance
  /// update in [StockLedger] would refuse a shortfall on its own, and does, but
  /// checking up front means the message names the item that is actually short rather
  /// than whichever one happened to be applied first, and it keeps a doomed attempt
  /// from doing any work.
  static Future<List<StockMovement>> _movementsFor(
    DatabaseExecutor db, {
    required String orderId,
    required _Requirements requirements,
    required DateTime at,
  }) async {
    if (requirements.isEmpty) {
      return const <StockMovement>[];
    }

    final Map<String, _Shelf> shelves = await _shelves(
      db,
      requirements.itemIds,
    );
    final List<StockMovement> movements = <StockMovement>[];

    // Sorted by stock item id so the movements of one bill are written in a
    // deterministic order. Nothing depends on the order for correctness; it makes the
    // ledger reproducible, which matters when two terminals ever compare notes.
    final List<String> itemIds = requirements.itemIds.toList()..sort();

    for (final String itemId in itemIds) {
      final int required = requirements.totals[itemId]!;
      final _Shelf? shelf = shelves[itemId];

      if (shelf == null) {
        throw ArgumentError.value(
          itemId,
          'inventoryItemId',
          'A recipe on this bill uses a stock item that no longer exists',
        );
      }
      if (shelf.availableMilli < required) {
        throw ArgumentError.value(
          itemId,
          'inventoryItemId',
          StockLedger.shortfallMessage(
            name: shelf.name,
            unit: shelf.unit,
            requiredMilli: required,
            availableMilli: shelf.availableMilli,
          ),
        );
      }

      movements.add(
        StockMovement(
          id: EntityId.generate(prefix: 'stk'),
          inventoryItemId: itemId,
          movementType: StockMovementType.sale,
          quantityMilli: required,
          // The reference is the settled bill, which is what makes a sale deduction
          // identifiable in the ledger and what the idempotency record is keyed on.
          referenceId: orderId,
          // The bill's own instant, not now. A deduction retried a day later belongs
          // to the sale that caused it, so the ledger reads in the order things were
          // sold rather than in the order they happened to be processed.
          createdAt: at,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }

    return movements;
  }

  static Future<Map<String, _Shelf>> _shelves(
    DatabaseExecutor db,
    Set<String> itemIds,
  ) async {
    final String placeholders = List<String>.filled(
      itemIds.length,
      '?',
    ).join(', ');

    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.inventoryItems,
      columns: <String>['id', 'name', 'unit', 'currentQuantityMilli'],
      where: 'id IN ($placeholders) AND isDeleted = 0',
      whereArgs: itemIds.toList(growable: false),
    );

    return <String, _Shelf>{
      for (final Map<String, Object?> row in rows)
        row['id']! as String: _Shelf(
          name: row['name']! as String,
          unit: StockUnit.read(row['unit']! as String),
          availableMilli: row['currentQuantityMilli']! as int,
        ),
    };
  }
}

/// The bill being deducted for, reduced to what the deduction needs.
class _SettledBill {
  const _SettledBill({required this.orderNumber, required this.at});

  final String orderNumber;

  /// When the bill was settled. Stamped onto the movements.
  final DateTime at;
}

/// One persisted bill line.
class _SoldLine {
  const _SoldLine({
    required this.menuItemId,
    required this.variantId,
    required this.displayName,
    required this.quantity,
  });

  /// Reporting back-reference to the product. Nullable, exactly as it is on the row.
  final String? menuItemId;

  final String? variantId;

  /// The line as it appeared on the bill, for reporting a missing recipe.
  final String displayName;

  final int quantity;
}

/// What the whole bill needs, per stock item, and what it could not account for.
class _Requirements {
  const _Requirements({required this.totals, required this.unconfiguredItems});

  /// Stock item id to the total thousandths the bill consumes.
  final Map<String, int> totals;

  /// Display names of sold lines that had no recipe.
  final List<String> unconfiguredItems;

  bool get isEmpty => totals.isEmpty;

  Set<String> get itemIds => totals.keys.toSet();
}

/// A stock item's balance at the moment the deduction checked it.
class _Shelf {
  const _Shelf({
    required this.name,
    required this.unit,
    required this.availableMilli,
  });

  final String name;
  final StockUnit unit;
  final int availableMilli;
}
