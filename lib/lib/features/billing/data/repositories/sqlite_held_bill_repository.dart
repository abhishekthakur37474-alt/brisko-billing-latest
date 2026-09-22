import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../../menu/domain/models/menu_option_type.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cart_line.dart';
import '../../domain/models/cart_line_option.dart';
import '../../domain/models/held_bill.dart';
import '../../domain/models/held_bill_draft.dart';
import '../../domain/models/held_bill_status.dart';
import '../../domain/models/held_bill_summary.dart';
import '../../domain/repositories/held_bill_repository.dart';

/// SQLite implementation of [HeldBillRepository].
///
/// ## Three tables, one transaction
///
/// A held bill is a header, its lines and their options. Holding writes all three inside
/// one `transaction`, so a fault part way through leaves nothing behind and the same draft
/// can be retried on its own id. The lines and options are read back with the header when
/// a bill is resumed or inspected, and the cart is rebuilt from them rather than from the
/// menu — a bill resumed after a repricing restores what was put aside.
///
/// ## The list reads no lines
///
/// [loadHeldBills] reads only the header table. The total and the counts it shows come
/// from the denormalised columns written when the bill was held, so telling two held bills
/// apart costs one query rather than one per bill plus its lines and options.
///
/// ## State is the guard
///
/// Only a bill at [HeldBillStatus.held] is on the terminal. [resume] and [cancel] re-read
/// the stored status inside their transaction and refuse a move that is not legal from it,
/// which is what makes two cashiers acting on one bill safe: the single SQLite connection
/// serialises the transactions, so the second sees the first's committed status and is
/// turned away.
///
/// ## Money
///
/// Every amount is read from and written to an `INTEGER` paise column through [Money].
/// Nothing here parses or formats a decimal.
class SqliteHeldBillRepository implements HeldBillRepository {
  SqliteHeldBillRepository({required this._database});

  final SqliteDatabase _database;

  Database get _db => _database.database;

  /// Tables a held-bill write touches, woken together once a transaction commits.
  static const List<String> _tables = <String>[
    SqliteTables.heldBills,
    SqliteTables.heldBillLines,
    SqliteTables.heldBillLineOptions,
  ];

  @override
  Future<Result<HeldBill>> hold(HeldBillDraft draft) {
    return SqliteErrorMapper.guard<HeldBill>(() async {
      // Refused before the transaction opens: an empty held bill would appear in the list
      // as something to resume and hand back nothing.
      if (!draft.hasLines) {
        throw ArgumentError.value(
          draft.id,
          'draft',
          'There is nothing on this bill to hold.',
        );
      }

      final HeldBill record = draft.toHeldBill();

      await _db.transaction((Transaction txn) async {
        // The draft's id is fixed, so a second submission of the same hold lands here. A
        // plain upsert would rewrite the header and append a second copy of every line, so
        // the existence check is what keeps a double tap to one bill.
        final List<Map<String, Object?>> existing = await txn.query(
          SqliteTables.heldBills,
          columns: <String>[SyncColumns.id],
          where: '${SyncColumns.id} = ?',
          whereArgs: <Object?>[record.id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          throw ArgumentError.value(
            record.id,
            'draft',
            'This bill has already been held.',
          );
        }

        await SqliteUpsert.run(txn, SqliteTables.heldBills, record.toMap());
        await _writeLines(txn, record);
      });

      // After the commit, never inside it.
      _database.notifyTablesChanged(_tables);
      return record;
    }, context: 'hold the bill');
  }

  @override
  Future<Result<HeldBill?>> findHeldBill(String id) {
    return SqliteErrorMapper.guard<HeldBill?>(() async {
      return _readHeldBill(_db, id);
    }, context: 'read the held bill');
  }

  @override
  Future<Result<List<HeldBillSummary>>> loadHeldBills() {
    return SqliteErrorMapper.guard<List<HeldBillSummary>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.heldBills,
        where: 'status = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[HeldBillStatus.held.name],
        // Oldest first: the bill waiting longest is at the top of the list.
        orderBy: '${SyncColumns.createdAt} ASC, rowid ASC',
      );
      return rows.map(HeldBillSummary.fromRow).toList(growable: false);
    }, context: 'load the held bills');
  }

  @override
  Future<Result<HeldBill>> resume(String id) =>
      _transition(id, to: HeldBillStatus.resumed);

  @override
  Future<Result<HeldBill>> cancel(String id) =>
      _transition(id, to: HeldBillStatus.cancelled);

  // --------------------------------------------------------------- internals ---

  /// Moves a held bill to [to], refusing anything that is not a legal move from its
  /// current stored state, and returns the bill as it now stands.
  ///
  /// The read and the write share one transaction, so the status a move is checked
  /// against is the status the move is applied to. On the single SQLite connection the
  /// application uses, that is what makes two simultaneous moves resolve to one winner:
  /// the second transaction sees the first's committed status and is refused.
  Future<Result<HeldBill>> _transition(
    String id, {
    required HeldBillStatus to,
  }) {
    return SqliteErrorMapper.guard<HeldBill>(
      () async {
        await _db.transaction((Transaction txn) async {
          final HeldBillStatus current = await _requireStatus(txn, id);
          _refuseIllegalMove(current, to: to);

          await txn.update(
            SqliteTables.heldBills,
            <String, Object?>{
              'status': to.name,
              SyncColumns.updatedAt: DateTime.now()
                  .toUtc()
                  .millisecondsSinceEpoch,
              // The status change is itself a change no backend has seen.
              SyncColumns.syncState: SyncState.pending.name,
            },
            where: '${SyncColumns.id} = ?',
            whereArgs: <Object?>[id],
          );
        });

        _database.notifyTablesChanged(_tables);

        // Re-read whole, so the caller gets the resumed cart and the new status together.
        final HeldBill? updated = await _readHeldBill(_db, id);
        if (updated == null) {
          // Cannot happen: the row was just updated inside a committed transaction. Guarded
          // so a caller never unwraps a null.
          throw StateError('The held bill disappeared after being updated.');
        }
        return updated;
      },
      context: to == HeldBillStatus.resumed
          ? 'resume the held bill'
          : 'cancel the held bill',
    );
  }

  /// The stored status of [id], or an [ArgumentError] if no such bill was ever held.
  Future<HeldBillStatus> _requireStatus(Transaction txn, String id) async {
    final List<Map<String, Object?>> rows = await txn.query(
      SqliteTables.heldBills,
      columns: <String>['status'],
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        'That bill is no longer on this terminal.',
      );
    }
    return rows.first.requireEnum<HeldBillStatus>(
      'status',
      HeldBillStatus.values,
      fallback: HeldBillStatus.cancelled,
    );
  }

  /// Refuses a move that is not legal from [current], with the reason the cashier reads.
  ///
  /// Only a held bill can be resumed or cancelled. A resumed or cancelled bill is
  /// terminal, so every move from one is refused, and the message names the state it is
  /// already in rather than the state that was asked for.
  void _refuseIllegalMove(
    HeldBillStatus current, {
    required HeldBillStatus to,
  }) {
    if (current == HeldBillStatus.held) {
      return;
    }
    final String reason = switch (current) {
      HeldBillStatus.resumed => 'This bill has already been resumed.',
      HeldBillStatus.cancelled => 'This bill has already been cancelled.',
      HeldBillStatus.held => '',
    };
    throw ArgumentError.value(to.name, 'status', reason);
  }

  /// Reads one held bill whole from [db], rebuilding its cart from the stored lines.
  ///
  /// Returns `null` when no header with [id] exists. A cancelled bill still comes back,
  /// because its row is kept for audit.
  Future<HeldBill?> _readHeldBill(DatabaseExecutor db, String id) async {
    final List<Map<String, Object?>> headerRows = await db.query(
      SqliteTables.heldBills,
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (headerRows.isEmpty) {
      return null;
    }

    final Cart cart = await _readCart(db, id);
    return HeldBill.fromRow(headerRows.first, cart: cart);
  }

  /// Rebuilds the cart of held bill [heldBillId] from its line and option rows.
  ///
  /// Two queries, not one per line: the lines, then every option for those lines, grouped
  /// in memory. Both are read in stored `position` order so the resumed cart is in the
  /// order it was rung up in, and identically configured lines are not merged — a held
  /// snapshot has to come back as the cart that was held, not an equivalent one.
  Future<Cart> _readCart(DatabaseExecutor db, String heldBillId) async {
    final List<Map<String, Object?>> lineRows = await db.query(
      SqliteTables.heldBillLines,
      where: 'heldBillId = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[heldBillId],
      orderBy: 'position ASC, rowid ASC',
    );
    if (lineRows.isEmpty) {
      return const Cart.empty();
    }

    final Map<String, List<CartLineOption>> optionsByLine =
        await _optionsForLines(
          db,
          lineRows
              .map(
                (Map<String, Object?> row) => row.requireString(SyncColumns.id),
              )
              .toList(growable: false),
        );

    final List<CartLine> lines = lineRows
        .map(
          (Map<String, Object?> row) => CartLine(
            // The cart line's identity is the id it had in the live cart, kept so a
            // resumed quantity edit finds the same line.
            id: row.requireString('cartLineId'),
            menuItemId: row.requireString('menuItemId'),
            variantId: row.optionalString('variantId'),
            itemNameSnapshot: row.requireString('itemNameSnapshot'),
            variantNameSnapshot: row.optionalString('variantNameSnapshot'),
            basePriceSnapshot: Money.fromPaise(
              row.requireInt('basePriceSnapshotPaise'),
            ),
            quantity: row.requireInt('quantity'),
            options:
                optionsByLine[row.requireString(SyncColumns.id)] ??
                const <CartLineOption>[],
          ),
        )
        .toList(growable: false);

    return Cart(lines);
  }

  /// Every option for [lineIds], grouped by the held-bill-line row id they belong to.
  Future<Map<String, List<CartLineOption>>> _optionsForLines(
    DatabaseExecutor db,
    List<String> lineIds,
  ) async {
    if (lineIds.isEmpty) {
      return const <String, List<CartLineOption>>{};
    }

    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.heldBillLineOptions,
      where:
          'heldBillLineId IN (${_placeholders(lineIds.length)}) '
          'AND ${SyncColumns.isDeleted} = 0',
      whereArgs: lineIds,
      orderBy: 'position ASC, rowid ASC',
    );

    final Map<String, List<CartLineOption>> grouped =
        <String, List<CartLineOption>>{};
    for (final Map<String, Object?> row in rows) {
      grouped
          .putIfAbsent(
            row.requireString('heldBillLineId'),
            () => <CartLineOption>[],
          )
          .add(
            CartLineOption(
              optionId: row.requireString('optionId'),
              nameSnapshot: row.requireString('optionNameSnapshot'),
              optionType: row.requireEnum<MenuOptionType>(
                'optionType',
                MenuOptionType.values,
                fallback: MenuOptionType.addOn,
              ),
              priceSnapshot: Money.fromPaise(row.requireInt('pricePaise')),
            ),
          );
    }
    return grouped;
  }

  /// Writes the lines of [record] and their options, in the order they sit on the cart.
  ///
  /// The line and option row ids are allocated here, inside the transaction, exactly
  /// because the header id is not: a hold either commits whole or rolls back to nothing,
  /// so a retry is stopped at the header before a line is written.
  Future<void> _writeLines(Transaction txn, HeldBill record) async {
    final DateTime now = record.heldAt;
    int linePosition = 0;

    for (final CartLine line in record.lines) {
      final String lineId = EntityId.generate(prefix: 'hbl');
      await SqliteUpsert.run(txn, SqliteTables.heldBillLines, <String, Object?>{
        SyncColumns.id: lineId,
        SyncColumns.createdAt: now.millisecondsSinceEpoch,
        SyncColumns.updatedAt: now.millisecondsSinceEpoch,
        SyncColumns.isDeleted: 0,
        SyncColumns.syncState: SyncState.pending.name,
        'heldBillId': record.id,
        'cartLineId': line.id,
        'position': linePosition,
        'menuItemId': line.menuItemId,
        'variantId': line.variantId,
        'itemNameSnapshot': line.itemNameSnapshot,
        'variantNameSnapshot': line.variantNameSnapshot,
        'basePriceSnapshotPaise': line.basePriceSnapshot.paise,
        'quantity': line.quantity,
      });
      linePosition++;

      int optionPosition = 0;
      for (final CartLineOption option in line.options) {
        await SqliteUpsert.run(
          txn,
          SqliteTables.heldBillLineOptions,
          <String, Object?>{
            SyncColumns.id: EntityId.generate(prefix: 'hblo'),
            SyncColumns.createdAt: now.millisecondsSinceEpoch,
            SyncColumns.updatedAt: now.millisecondsSinceEpoch,
            SyncColumns.isDeleted: 0,
            SyncColumns.syncState: SyncState.pending.name,
            'heldBillLineId': lineId,
            'optionId': option.optionId,
            'optionNameSnapshot': option.nameSnapshot,
            'optionType': option.optionType.name,
            'pricePaise': option.priceSnapshot.paise,
            'position': optionPosition,
          },
        );
        optionPosition++;
      }
    }
  }

  /// `?, ?, ?` for an `IN` clause. Values are always bound, never interpolated.
  static String _placeholders(int count) =>
      List<String>.filled(count, '?').join(', ');
}
