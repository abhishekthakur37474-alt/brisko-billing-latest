import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_local_store.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/kitchen_ticket.dart';
import '../../domain/models/kitchen_ticket_draft.dart';
import '../../domain/models/kot_item.dart';
import '../../domain/models/kot_item_option.dart';
import '../../domain/models/kot_record.dart';
import '../../domain/models/kot_status.dart';
import '../../domain/repositories/kot_repository.dart';
import '../kot_number_sequence.dart';
import '../sqlite_kot_writer.dart';

/// SQLite implementation of [KotRepository].
class SqliteKotRepository implements KotRepository {
  SqliteKotRepository({required SqliteDatabase database})
    : _database = database,
      _records = SqliteLocalStore<KotRecord>(
        database: database,
        table: SqliteTables.kotRecords,
        fromRow: KotRecord.fromRow,
        orderBy: 'createdAt ASC',
      );

  final SqliteDatabase _database;
  final SqliteLocalStore<KotRecord> _records;

  Database get _db => _database.database;

  @override
  Future<Result<void>> createKot(
    KotRecord record,
    List<KotItem> items, {
    List<KotItemOption> itemOptions = const <KotItemOption>[],
  }) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        await SqliteKotWriter.write(
          txn,
          KitchenTicketDraft(
            record: record,
            items: items,
            itemOptions: itemOptions,
          ),
        );
      });

      // After the commit, never inside it.
      _database.notifyTablesChanged(SqliteKotWriter.tables);
    }, context: 'create the kitchen slip');
  }

  @override
  Future<Result<KotRecord?>> findKot(String id) => _records.findById(id);

  @override
  Future<Result<List<KotRecord>>> loadForOrder(String orderId) {
    return SqliteErrorMapper.guard<List<KotRecord>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.kotRecords,
        where: 'orderId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(KotRecord.fromRow).toList(growable: false);
    }, context: 'load the kitchen slips');
  }

  /// Lines are ordered by `createdAt` and then by SQLite's implicit `rowid`.
  ///
  /// Every line of a slip carries the same `createdAt`, because they were all
  /// written by one settlement, so `rowid` is what actually orders them. It
  /// increases with each insert, which reproduces the sequence the cashier entered.
  /// A slip whose lines reorder between reads would be read out to the kitchen in a
  /// different order each time.
  @override
  Future<Result<List<KotItem>>> loadItems(String kotId) {
    return SqliteErrorMapper.guard<List<KotItem>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.kotItems,
        where: 'kotId = ? AND isDeleted = 0',
        whereArgs: <Object?>[kotId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(KotItem.fromRow).toList(growable: false);
    }, context: 'load the slip lines');
  }

  @override
  Future<Result<List<KotItemOption>>> loadItemOptions(String kotItemId) {
    return SqliteErrorMapper.guard<List<KotItemOption>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.kotItemOptions,
        where: 'kotItemId = ? AND isDeleted = 0',
        whereArgs: <Object?>[kotItemId],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(KotItemOption.fromRow).toList(growable: false);
    }, context: 'load the slip line options');
  }

  @override
  Future<Result<List<KotRecord>>> loadPending() {
    return SqliteErrorMapper.guard<List<KotRecord>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.kotRecords,
        where: 'status = ? AND isDeleted = 0',
        whereArgs: <Object?>[KotStatus.pending.name],
        orderBy: 'createdAt ASC, rowid ASC',
      );
      return rows.map(KotRecord.fromRow).toList(growable: false);
    }, context: 'load pending kitchen slips');
  }

  /// Three queries, not one per slip.
  ///
  /// The board is read on every visit to the section, and an N+1 over lines and then
  /// options would be two queries per slip. Instead the headers are read, then every
  /// line for those slips, then every option for those lines, and the three are
  /// stitched together in memory.
  @override
  Future<Result<List<KitchenTicket>>> loadActiveTickets() {
    final List<KotStatus> active = KotStatus.values
        .where((KotStatus status) => status.isActive)
        .toList(growable: false);

    return SqliteErrorMapper.guard<List<KitchenTicket>>(
      () => _tickets(
        where: 'status IN (${_placeholders(active.length)}) AND isDeleted = 0',
        whereArgs: active
            .map((KotStatus status) => status.name)
            .toList(growable: false),
        orderBy: 'createdAt DESC, rowid DESC',
      ),
      context: 'load the kitchen board',
    );
  }

  @override
  Future<Result<List<KitchenTicket>>> loadTicketsForOrder(String orderId) {
    return SqliteErrorMapper.guard<List<KitchenTicket>>(
      () => _tickets(
        where: 'orderId = ? AND isDeleted = 0',
        whereArgs: <Object?>[orderId],
      ),
      context: 'load the kitchen slips',
    );
  }

  @override
  Future<Result<String>> nextKotNumber() {
    return SqliteErrorMapper.guard<String>(
      () => KotNumberSequence.next(_db),
      context: 'allocate a kitchen slip number',
    );
  }

  @override
  Future<Result<void>> advanceStatus(String kotId, KotStatus next) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.transaction((Transaction txn) async {
        final List<Map<String, Object?>> rows = await txn.query(
          SqliteTables.kotRecords,
          columns: <String>['status'],
          where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
          whereArgs: <Object?>[kotId],
          limit: 1,
        );

        // ArgumentError so the error mapper reports these as a ValidationFailure
        // carrying the message, rather than as an unexpected fault. Both are
        // recoverable: the board reloads and shows the operator the real state.
        if (rows.isEmpty) {
          throw ArgumentError.value(
            kotId,
            'kotId',
            'That kitchen slip no longer exists.',
          );
        }

        final KotStatus current = rows.first.requireEnum<KotStatus>(
          'status',
          KotStatus.values,
          fallback: KotStatus.pending,
        );

        if (!current.canAdvanceTo(next)) {
          throw ArgumentError.value(
            next.name,
            'status',
            'A slip that is already ${current.label.toLowerCase()} cannot be '
                'moved to ${next.label.toLowerCase()}.',
          );
        }

        await _writeStatus(txn, kotId, next);
      });

      _database.notifyTableChanged(SqliteTables.kotRecords);
    }, context: 'update the kitchen slip');
  }

  @override
  Future<Result<void>> updateStatus(String kotId, KotStatus status) {
    return SqliteErrorMapper.guard<void>(() async {
      await _writeStatus(_db, kotId, status);
      _database.notifyTableChanged(SqliteTables.kotRecords);
    }, context: 'update the kitchen slip');
  }

  // --------------------------------------------------------------- internals ---

  /// Assembles slips matching [where] into tickets.
  ///
  /// [orderBy] defaults to oldest first, which is the print sequence for one order.
  /// The kitchen board passes newest first so a just-settled slip sits at the top.
  ///
  /// Three queries, not one per slip: the headers, then every line for those slips,
  /// then every option for those lines, stitched together in memory. The board is read
  /// on every visit to the section, so an N+1 over lines and then options would be two
  /// queries per slip.
  Future<List<KitchenTicket>> _tickets({
    required String where,
    required List<Object?> whereArgs,
    String orderBy = 'createdAt ASC, rowid ASC',
  }) async {
    final List<Map<String, Object?>> recordRows = await _db.query(
      SqliteTables.kotRecords,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
    );

    final List<KotRecord> records = recordRows
        .map(KotRecord.fromRow)
        .toList(growable: false);
    if (records.isEmpty) {
      return const <KitchenTicket>[];
    }

    final List<KotItem> items = await _itemsForKots(
      records.map((KotRecord record) => record.id).toList(growable: false),
    );
    final Map<String, List<KotItemOption>> optionsByItem =
        await _optionsForItems(
          items.map((KotItem item) => item.id).toList(growable: false),
        );

    final Map<String, List<KitchenTicketLine>> linesByKot =
        <String, List<KitchenTicketLine>>{};
    for (final KotItem item in items) {
      linesByKot
          .putIfAbsent(item.kotId, () => <KitchenTicketLine>[])
          .add(
            KitchenTicketLine(
              item: item,
              options: optionsByItem[item.id] ?? const <KotItemOption>[],
            ),
          );
    }

    return records
        .map(
          (KotRecord record) => KitchenTicket(
            record: record,
            lines: linesByKot[record.id] ?? const <KitchenTicketLine>[],
          ),
        )
        .toList(growable: false);
  }

  Future<void> _writeStatus(
    DatabaseExecutor db,
    String kotId,
    KotStatus status,
  ) async {
    await db.update(
      SqliteTables.kotRecords,
      <String, Object?>{
        'status': status.name,
        SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
        // Back to pending: the status change is itself a change the cloud has not
        // seen.
        SyncColumns.syncState: SyncState.pending.name,
      },
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[kotId],
    );
  }

  Future<List<KotItem>> _itemsForKots(List<String> kotIds) async {
    final List<Map<String, Object?>> rows = await _db.query(
      SqliteTables.kotItems,
      where: 'kotId IN (${_placeholders(kotIds.length)}) AND isDeleted = 0',
      whereArgs: kotIds,
      orderBy: 'createdAt ASC, rowid ASC',
    );
    return rows.map(KotItem.fromRow).toList(growable: false);
  }

  Future<Map<String, List<KotItemOption>>> _optionsForItems(
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) {
      return const <String, List<KotItemOption>>{};
    }

    final List<Map<String, Object?>> rows = await _db.query(
      SqliteTables.kotItemOptions,
      where:
          'kotItemId IN (${_placeholders(itemIds.length)}) AND isDeleted = 0',
      whereArgs: itemIds,
      orderBy: 'createdAt ASC, rowid ASC',
    );

    final Map<String, List<KotItemOption>> grouped =
        <String, List<KotItemOption>>{};
    for (final Map<String, Object?> row in rows) {
      final KotItemOption option = KotItemOption.fromRow(row);
      grouped
          .putIfAbsent(option.kotItemId, () => <KotItemOption>[])
          .add(option);
    }
    return grouped;
  }

  /// `?, ?, ?` for an `IN` clause. Values are always bound, never interpolated.
  static String _placeholders(int count) =>
      List<String>.filled(count, '?').join(', ');
}
