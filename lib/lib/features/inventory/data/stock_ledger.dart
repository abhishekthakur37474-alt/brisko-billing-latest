import 'package:sqflite/sqflite.dart';

import '../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../core/data/sync/sync_state.dart';
import '../domain/models/stock_movement.dart';
import '../domain/models/stock_quantity.dart';
import '../domain/models/stock_unit.dart';

/// Applies a movement to an item's running balance, and records it.
///
/// Takes a [DatabaseExecutor] rather than owning a connection, so the same code serves
/// both callers: the inventory repository, recording what an operator did, and the
/// deduction, taking a settled bill's ingredients off the shelf inside its own
/// transaction. One implementation means the manual and the automatic paths cannot
/// drift into keeping the balance differently — in particular, they cannot drift on
/// whether stock is allowed to go negative.
///
/// ## Balance first, then ledger row
///
/// [record] changes the balance and then inserts the movement. Either order would be
/// atomic, since both happen in the caller's transaction, so the reason for this one is
/// the message the operator ends up reading. The balance update carries every condition
/// worth checking — the item exists, it is not deleted, and the result is not negative —
/// and it refuses with a sentence naming the item and the shortfall. Inserting the
/// ledger row first would instead trip the foreign key on a missing item, and a foreign
/// key violation is reported as a storage fault, which tells the operator nothing.
class StockLedger {
  const StockLedger._();

  /// Tables a movement touches. Watchers on both are woken once the caller's
  /// transaction commits.
  static const List<String> tables = <String>[
    SqliteTables.stockMovements,
    SqliteTables.inventoryItems,
  ];

  /// Applies [movement] to its item's balance and writes it to the ledger.
  ///
  /// Must be called inside a transaction the caller owns. A refusal throws, which takes
  /// that transaction — and therefore both writes — down with it, so there is no such
  /// thing as a balance without its movement or a movement without its balance.
  ///
  /// ## Why the balance is one relative UPDATE and not a read followed by a write
  ///
  /// The new balance is computed by SQLite from the stored value, and the same
  /// statement carries the condition that the result must not be negative. So the
  /// check and the change are a single atomic operation: there is no instant between
  /// reading a balance and writing it during which another movement could land, and
  /// therefore no way for two movements to each see enough stock and jointly overdraw
  /// it.
  ///
  /// Throws [ArgumentError] when the balance matched no row, which the error mapper
  /// reports as a `ValidationFailure`. That happens for exactly two reasons, and they
  /// are distinguished so the message is useful: the item does not exist, or the
  /// movement would take it below zero.
  static Future<void> record(
    DatabaseExecutor db, {
    required StockMovement movement,
    required DateTime at,
  }) async {
    final int signed = movement.signedQuantityMilli;

    final int updated = await db.rawUpdate(
      'UPDATE ${SqliteTables.inventoryItems} '
      'SET currentQuantityMilli = currentQuantityMilli + ?, '
      '    ${SyncColumns.updatedAt} = ?, '
      '    ${SyncColumns.syncState} = ? '
      'WHERE ${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0 '
      '  AND currentQuantityMilli + ? >= 0',
      <Object?>[
        signed,
        at.millisecondsSinceEpoch,
        SyncState.pending.name,
        movement.inventoryItemId,
        signed,
      ],
    );

    if (updated != 1) {
      throw ArgumentError.value(
        movement.inventoryItemId,
        'inventoryItemId',
        await _refusalReason(db, movement),
      );
    }

    await db.insert(SqliteTables.stockMovements, movement.toMap());
  }

  /// Why the update matched no row, in operator-facing language.
  ///
  /// Read after the fact rather than before, so the happy path stays one statement.
  /// A refused movement is rare and a second query for it costs nothing; a
  /// pre-flight read on every movement would cost one on all of them and still not
  /// be safe.
  static Future<String> _refusalReason(
    DatabaseExecutor db,
    StockMovement movement,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.inventoryItems,
      columns: <String>['name', 'unit', 'currentQuantityMilli'],
      where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[movement.inventoryItemId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return 'No such stock item';
    }

    return shortfallMessage(
      name: rows.first['name']! as String,
      unit: StockUnit.read(rows.first['unit']! as String),
      requiredMilli: movement.signedQuantityMilli.abs(),
      availableMilli: rows.first['currentQuantityMilli']! as int,
    );
  }

  /// The one wording used whenever there is not enough of something.
  ///
  /// Shared with the deduction so that a shortfall reads the same whether the
  /// operator hit it recording wastage or a bill hit it deducting a recipe. It names
  /// the item, what was needed and what is there, because "insufficient stock" alone
  /// tells nobody how much to go and count.
  static String shortfallMessage({
    required String name,
    required StockUnit unit,
    required int requiredMilli,
    required int availableMilli,
  }) {
    final String needed = unit.describe(StockQuantity.format(requiredMilli));
    final String have = unit.describe(StockQuantity.format(availableMilli));
    return 'Not enough $name: $needed needed, $have in stock';
  }
}
