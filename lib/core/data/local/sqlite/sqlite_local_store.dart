import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../utils/entity_id.dart';
import '../../../utils/result.dart';
import '../../local_store.dart';
import '../../sync/outbox_entry.dart';
import '../../sync/outbox_store.dart';
import '../../sync/remote_merge_report.dart';
import '../../sync/sync_state.dart';
import '../../sync/syncable_entity.dart';
import 'sqlite_database.dart';
import 'sqlite_error_mapper.dart';
import 'sqlite_tables.dart';
import 'sqlite_upsert.dart';

/// SQLite-backed implementation of [LocalStore] for one table.
///
/// Generic on purpose: the CRUD surface every syncable entity needs is identical,
/// so it is written once here and each repository composes an instance per table.
/// Queries specific to a feature, such as finding a customer by phone or loading
/// an order with its lines, live in that feature's repository implementation. All
/// of it stays inside the data layer, so no SQL reaches a widget.
///
/// Every read filters out soft-deleted rows. A caller that wants them must query
/// explicitly through a repository.
class SqliteLocalStore<T extends SyncableEntity> implements LocalStore<T> {
  SqliteLocalStore({
    required this.database,
    required this.table,
    required this.fromRow,
    this.orderBy,
    this.outbox,
    String? collection,
  }) : _collection = collection ?? table;

  final SqliteDatabase database;

  /// Table this store reads and writes.
  final String table;

  /// Builds an entity from a result row.
  final T Function(Map<String, Object?> row) fromRow;

  /// Default sort applied by [findAll] and [watchAll].
  final String? orderBy;

  /// Optional durable queue for changes that should reach a cloud backend.
  ///
  /// Left `null` for now. The outbox table and [OutboxStore] implementation exist
  /// and are tested, but nothing drains them yet because there is no backend, and
  /// an undrained queue would grow without bound for every bill the outlet ever
  /// takes. Supplying an outbox here is the single change that switches enqueueing
  /// on, at the point a `RemoteStore` and `SyncCoordinator` are actually wired up.
  final OutboxStore? outbox;

  final String _collection;

  Database get _db => database.database;

  @override
  Future<Result<T?>> findById(String id) {
    return SqliteErrorMapper.guard<T?>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        table,
        where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return rows.isEmpty ? null : fromRow(rows.first);
    }, context: 'load the record');
  }

  @override
  Future<Result<List<T>>> findAll() {
    return SqliteErrorMapper.guard<List<T>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        table,
        where: '${SyncColumns.isDeleted} = 0',
        orderBy: orderBy,
      );
      return rows.map(fromRow).toList(growable: false);
    }, context: 'load records');
  }

  @override
  Future<Result<void>> save(T entity) {
    return SqliteErrorMapper.guard<void>(() async {
      await SqliteUpsert.run(_db, table, entity.toMap());
      await _enqueue(entity, OutboxOperation.upsert);
      database.notifyTableChanged(table);
    }, context: 'save the record');
  }

  @override
  Future<Result<void>> saveAll(Iterable<T> entities) {
    return SqliteErrorMapper.guard<void>(() async {
      if (entities.isEmpty) {
        return;
      }
      // One transaction so a partial write cannot leave the table inconsistent.
      await _db.transaction((Transaction txn) async {
        for (final T entity in entities) {
          await SqliteUpsert.run(txn, table, entity.toMap());
        }
      });
      for (final T entity in entities) {
        await _enqueue(entity, OutboxOperation.upsert);
      }
      database.notifyTableChanged(table);
    }, context: 'save records');
  }

  @override
  Future<Result<void>> softDelete(String id) {
    return SqliteErrorMapper.guard<void>(() async {
      final int updated = await _db.update(
        table,
        <String, Object?>{
          SyncColumns.isDeleted: 1,
          SyncColumns.updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          // Back to pending: the deletion is itself a change the cloud has not
          // seen.
          SyncColumns.syncState: SyncState.pending.name,
        },
        where: '${SyncColumns.id} = ?',
        whereArgs: <Object?>[id],
      );

      if (updated == 0) {
        return;
      }

      await _enqueueDelete(id);
      database.notifyTableChanged(table);
    }, context: 'delete the record');
  }

  @override
  Future<Result<List<T>>> findUnsynced() {
    return SqliteErrorMapper.guard<List<T>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        table,
        where: '${SyncColumns.syncState} != ?',
        whereArgs: <Object?>[SyncState.synced.name],
        orderBy: SyncColumns.updatedAt,
      );
      return rows.map(fromRow).toList(growable: false);
    }, context: 'load unsynced records');
  }

  @override
  Future<Result<void>> markSynced(String id, DateTime version) {
    return SqliteErrorMapper.guard<void>(() async {
      // Guarded on updatedAt: if the record changed after it was pushed, the
      // stored timestamp no longer matches the version that reached the cloud, so
      // it is left pending and the newer edit is uploaded on the next cycle.
      final int updated = await _db.update(
        table,
        <String, Object?>{SyncColumns.syncState: SyncState.synced.name},
        where:
            '${SyncColumns.id} = ? AND ${SyncColumns.updatedAt} = ? '
            'AND ${SyncColumns.syncState} != ?',
        whereArgs: <Object?>[
          id,
          version.toUtc().millisecondsSinceEpoch,
          SyncState.synced.name,
        ],
      );
      if (updated > 0) {
        database.notifyTableChanged(table);
      }
    }, context: 'mark the record synced');
  }

  @override
  Future<Result<RemoteMergeReport>> applyRemoteChanges(Iterable<T> entities) {
    return SqliteErrorMapper.guard<RemoteMergeReport>(() async {
      final List<T> incoming = entities.toList(growable: false);
      if (incoming.isEmpty) {
        return const RemoteMergeReport.empty();
      }

      int applied = 0;
      int keptLocal = 0;

      await _db.transaction((Transaction txn) async {
        for (final T entity in incoming) {
          if (await _mergeOne(txn, entity)) {
            applied++;
          } else {
            keptLocal++;
          }
        }
      });

      if (applied > 0) {
        database.notifyTableChanged(table);
      }
      return RemoteMergeReport(applied: applied, keptLocal: keptLocal);
    }, context: 'apply cloud changes');
  }

  /// Merges one pulled [entity] into [table] under last-write-wins, returning true
  /// when it was written and false when the local copy was kept.
  ///
  /// The conflict is resolved against whichever local row the incoming one would
  /// collide with: first the row with the same stable [SyncableEntity.id], and — if
  /// there is none by id — a row that shares a *natural* unique key, such as an
  /// `orderNumber` or a once-per-order deduction. That second case is the one this
  /// method exists for: a record re-created on another terminal carries a new id but
  /// the same business key, so a plain `INSERT … ON CONFLICT (id)` would hit a
  /// *secondary* unique index and throw "That record already exists.", failing the
  /// whole pull. Resolving against the colliding row instead makes the pull
  /// idempotent and safe.
  ///
  /// Last-write-wins and soft-delete are preserved exactly: strictly-newer remote
  /// wins, older-or-equal is held back (protecting a newer local record, including a
  /// settled bill not yet uploaded), and a soft-deleted local row still counts as a
  /// timestamped change so an older cloud undelete cannot resurrect it.
  Future<bool> _mergeOne(Transaction txn, T entity) async {
    // A child record whose referenced parent does not exist locally (for example,
    // because the parent was held back by last-write-wins or superseded by a newer
    // record) cannot be inserted without violating SQLite foreign key constraints.
    // Holding it back preserves relational integrity and last-write-wins consistency.
    if (await _hasMissingParent(txn, entity)) {
      return false;
    }

    // Reads the local row including a soft-deleted one, because a delete is itself a
    // change with a timestamp.
    final List<Map<String, Object?>> byId = await txn.query(
      table,
      columns: <String>[SyncColumns.id, SyncColumns.updatedAt],
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[entity.id],
      limit: 1,
    );

    // No row shares the id: look for one that shares a natural unique key and would
    // therefore block the insert. This is the previously-fatal case.
    final Map<String, Object?>? conflict = byId.isNotEmpty
        ? byId.first
        : await _conflictingRow(txn, entity);

    final int remoteAt = entity.updatedAt.toUtc().millisecondsSinceEpoch;

    if (conflict != null) {
      final int localAt = conflict[SyncColumns.updatedAt]! as int;
      // Strictly newer wins. Older or equal is held back.
      if (remoteAt <= localAt) {
        return false;
      }
      final String conflictId = conflict[SyncColumns.id]! as String;
      // A colliding row under a *different* id is an older duplicate of the same
      // logical record (same order number, same once-per-order refund). The unique
      // index forbids keeping both, and last-write-wins says the newer cloud copy
      // stands, so the superseded local duplicate is removed inside this same
      // transaction before the newer version is written in its place. A same-id
      // collision needs no delete: the upsert updates it in place.
      //
      // The delete is cascaded: child tables use ON DELETE RESTRICT, so a bare
      // DELETE of an order that still has items, payments or kitchen slips would
      // fail the whole pull with SQLITE 1811. Descendants of the superseded
      // duplicate are removed with it; the remote graph arrives on later pulls.
      if (conflictId != entity.id) {
        await _deleteRowCascade(txn, table, conflictId);
      }
    }

    // Stored as synced: it now matches the cloud, so it must not be queued straight
    // back for upload.
    final Map<String, dynamic> values = Map<String, dynamic>.from(entity.toMap())
      ..[SyncColumns.syncState] = SyncState.synced.name;

    await SqliteUpsert.run(txn, table, values);
    return true;
  }

  /// The local row an insert of [entity] would collide with on a *secondary* unique
  /// index (i.e. any unique index other than the primary key on `id`), or null when
  /// none would.
  ///
  /// Driven by SQLite's own catalogue via `PRAGMA index_list`/`index_info`, so it
  /// covers every unique index the schema has now — `orders.orderNumber`,
  /// `kot_records.kotNumber`, the once-per-order `refunds`/`order_inventory_deductions`
  /// keys, the recipe-ingredient keys — and any added later, without a hand-maintained
  /// list to keep in step. Partial indexes are honoured naturally: a row that the
  /// index does not cover simply matches nothing.
  Future<Map<String, Object?>?> _conflictingRow(
    Transaction txn,
    T entity,
  ) async {
    final Map<String, dynamic> row = entity.toMap();

    for (final _UniqueIndex index in await _uniqueIndexColumns(txn)) {
      final List<String> columns = index.columns;
      // A unique index constrains only rows where every indexed column is non-null
      // (SQLite treats NULLs as distinct), so a row with a null in any of them can
      // never collide on this index.
      if (columns.any((String c) => row[c] == null)) {
        continue;
      }
      final String predicate = columns
          .map((String c) => '$c = ?')
          .join(' AND ');
      // A partial index (a `CREATE UNIQUE INDEX … WHERE …`, as used for the
      // soft-delete-aware refund key and the recipe-ingredient keys) only enforces
      // uniqueness over the rows its WHERE clause covers. Applying the same clause
      // here means a row the index does not police — a soft-deleted refund, say —
      // is not mistaken for a blocker.
      final String? where = index.whereClause;
      final List<Map<String, Object?>> matches = await txn.query(
        table,
        columns: <String>[SyncColumns.id, SyncColumns.updatedAt],
        where:
            '$predicate AND ${SyncColumns.id} != ?'
            '${where == null ? '' : ' AND ($where)'}',
        whereArgs: <Object?>[
          ...columns.map((String c) => row[c]),
          entity.id,
        ],
        limit: 1,
      );
      if (matches.isNotEmpty) {
        return matches.first;
      }
    }
    return null;
  }

  /// Every unique index on [table] SQLite would enforce, excluding the primary key
  /// (handled by the id upsert). Cached per store, because the schema does not change
  /// while the database is open.
  List<_UniqueIndex>? _uniqueIndexColumnsCache;

  Future<List<_UniqueIndex>> _uniqueIndexColumns(Transaction txn) async {
    final List<_UniqueIndex>? cached = _uniqueIndexColumnsCache;
    if (cached != null) {
      return cached;
    }

    final List<_UniqueIndex> result = <_UniqueIndex>[];
    final List<Map<String, Object?>> indexes = await txn.rawQuery(
      'PRAGMA index_list($table)',
    );
    for (final Map<String, Object?> index in indexes) {
      // `unique` is 1 for a unique index; `origin` is 'pk' for the primary key,
      // 'u' for a UNIQUE constraint, 'c' for a CREATE UNIQUE INDEX. The primary key
      // is already handled by ON CONFLICT (id), so it is skipped here.
      final bool isUnique = (index['unique'] as int?) == 1;
      final String origin = (index['origin'] as String?) ?? '';
      if (!isUnique || origin == 'pk') {
        continue;
      }
      final String name = index['name']! as String;
      final List<Map<String, Object?>> info = await txn.rawQuery(
        'PRAGMA index_info($name)',
      );
      final List<String> columns = <String>[
        for (final Map<String, Object?> column in info)
          column['name']! as String,
      ];
      if (columns.isEmpty) {
        continue;
      }
      result.add(
        _UniqueIndex(
          columns: columns,
          whereClause: await _indexWhereClause(txn, name),
        ),
      );
    }

    _uniqueIndexColumnsCache = result;
    return result;
  }

  /// The `WHERE …` predicate of a partial index [name], or null for a full index.
  ///
  /// `PRAGMA index_info` does not expose it, so it is read from the index's own
  /// `CREATE` statement in `sqlite_master`.
  Future<String?> _indexWhereClause(Transaction txn, String name) async {
    final List<Map<String, Object?>> rows = await txn.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
      <Object?>[name],
    );
    final String? sql = rows.isEmpty ? null : rows.first['sql'] as String?;
    if (sql == null) {
      // An auto-created index (a UNIQUE constraint) has no stored SQL; it is never
      // partial, so it has no predicate.
      return null;
    }
    final Match? match = RegExp(
      r'\bWHERE\b(.*)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(sql);
    return match?.group(1)?.trim();
  }

  /// Whether [entity] references a parent row that does not exist locally across any
  /// foreign key constraint on [table].
  ///
  /// Driven by SQLite's own catalogue via `PRAGMA foreign_key_list`, covering every
  /// foreign key on the table dynamically without a hand-maintained list. Null foreign
  /// key values are permitted by SQLite and are skipped.
  Future<bool> _hasMissingParent(Transaction txn, T entity) async {
    final Map<String, dynamic> row = entity.toMap();
    for (final _ForeignKey fk in await _foreignKeys(txn)) {
      final Object? value = row[fk.fromColumn];
      if (value == null) {
        continue;
      }
      final List<Map<String, Object?>> parent = await txn.query(
        fk.parentTable,
        columns: <String>[fk.toColumn],
        where: '${fk.toColumn} = ?',
        whereArgs: <Object?>[value],
        limit: 1,
      );
      if (parent.isEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Every foreign key constraint on [table]. Cached per store.
  List<_ForeignKey>? _foreignKeysCache;

  Future<List<_ForeignKey>> _foreignKeys(Transaction txn) async {
    final List<_ForeignKey>? cached = _foreignKeysCache;
    if (cached != null) {
      return cached;
    }

    final List<_ForeignKey> result = <_ForeignKey>[];
    final List<Map<String, Object?>> rows = await txn.rawQuery(
      'PRAGMA foreign_key_list($table)',
    );
    for (final Map<String, Object?> row in rows) {
      final String? parentTable = row['table'] as String?;
      final String? fromColumn = row['from'] as String?;
      final String toColumn = (row['to'] as String?) ?? SyncColumns.id;
      if (parentTable != null && fromColumn != null) {
        result.add(
          _ForeignKey(
            parentTable: parentTable,
            fromColumn: fromColumn,
            toColumn: toColumn,
          ),
        );
      }
    }

    _foreignKeysCache = result;
    return result;
  }

  /// Physically removes [id] from [targetTable], after first removing every row
  /// that references it (and those rows' own descendants).
  ///
  /// Required because the schema uses `ON DELETE RESTRICT`: a parent cannot be
  /// deleted while any child still points at it. Used only when last-write-wins
  /// collapses a superseded local duplicate onto a newer remote id — the remote
  /// graph of children is applied on subsequent collection pulls.
  Future<void> _deleteRowCascade(
    Transaction txn,
    String targetTable,
    String id,
  ) async {
    for (final _IncomingForeignKey child in await _incomingForeignKeys(
      txn,
      targetTable,
    )) {
      final List<Map<String, Object?>> dependents = await txn.query(
        child.childTable,
        columns: <String>[SyncColumns.id],
        where: '${child.fromColumn} = ?',
        whereArgs: <Object?>[id],
      );
      for (final Map<String, Object?> dependent in dependents) {
        final String? childId = dependent[SyncColumns.id] as String?;
        if (childId == null) {
          continue;
        }
        await _deleteRowCascade(txn, child.childTable, childId);
      }
    }
    await txn.delete(
      targetTable,
      where: '${SyncColumns.id} = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Incoming foreign keys that point *at* [targetTable], across the whole
  /// schema. Cached per (store, target) because the schema does not change while
  /// the database is open.
  final Map<String, List<_IncomingForeignKey>> _incomingForeignKeysCache =
      <String, List<_IncomingForeignKey>>{};

  Future<List<_IncomingForeignKey>> _incomingForeignKeys(
    Transaction txn,
    String targetTable,
  ) async {
    final List<_IncomingForeignKey>? cached =
        _incomingForeignKeysCache[targetTable];
    if (cached != null) {
      return cached;
    }

    final List<_IncomingForeignKey> result = <_IncomingForeignKey>[];
    final List<Map<String, Object?>> tables = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    for (final Map<String, Object?> tableRow in tables) {
      final String? childTable = tableRow['name'] as String?;
      if (childTable == null) {
        continue;
      }
      final List<Map<String, Object?>> fks = await txn.rawQuery(
        'PRAGMA foreign_key_list($childTable)',
      );
      for (final Map<String, Object?> fk in fks) {
        if ((fk['table'] as String?) != targetTable) {
          continue;
        }
        final String? fromColumn = fk['from'] as String?;
        if (fromColumn == null) {
          continue;
        }
        result.add(
          _IncomingForeignKey(childTable: childTable, fromColumn: fromColumn),
        );
      }
    }

    _incomingForeignKeysCache[targetTable] = result;
    return result;
  }

  @override
  Stream<List<T>> watchAll() {
    late final StreamController<List<T>> controller;
    StreamSubscription<String>? subscription;

    Future<void> emit() async {
      final Result<List<T>> result = await findAll();
      if (controller.isClosed) {
        return;
      }
      result.fold(onOk: controller.add, onErr: controller.addError);
    }

    controller = StreamController<List<T>>(
      onListen: () {
        subscription = database.tableChanges
            .where((String changedTable) => changedTable == table)
            .listen((String _) => unawaited(emit()));
        unawaited(emit());
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
        // The controller belongs to this subscription alone, so it is disposed
        // with it. Leaving it open would leak a listener on `tableChanges` for
        // every screen that has ever watched this table.
        await controller.close();
      },
    );

    return controller.stream;
  }

  Future<void> _enqueue(T entity, OutboxOperation operation) async {
    final OutboxStore? queue = outbox;
    if (queue == null) {
      return;
    }
    await queue.enqueue(
      OutboxEntry(
        id: EntityId.generate(prefix: 'obx'),
        collection: _collection,
        entityId: entity.id,
        operation: operation,
        payload: entity.toMap(),
        queuedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _enqueueDelete(String id) async {
    final OutboxStore? queue = outbox;
    if (queue == null) {
      return;
    }
    await queue.enqueue(
      OutboxEntry(
        id: EntityId.generate(prefix: 'obx'),
        collection: _collection,
        entityId: id,
        operation: OutboxOperation.delete,
        payload: const <String, Object?>{},
        queuedAt: DateTime.now().toUtc(),
      ),
    );
  }
}

/// One secondary unique index, as the merge needs to see it: the columns it spans
/// and, for a partial index, the `WHERE` predicate that bounds which rows it covers.
class _UniqueIndex {
  const _UniqueIndex({required this.columns, required this.whereClause});

  final List<String> columns;
  final String? whereClause;
}

/// One foreign key constraint on a table: the parent table and the columns it joins on.
class _ForeignKey {
  const _ForeignKey({
    required this.parentTable,
    required this.fromColumn,
    required this.toColumn,
  });

  final String parentTable;
  final String fromColumn;
  final String toColumn;
}

/// A foreign key on some other table that references this one.
class _IncomingForeignKey {
  const _IncomingForeignKey({
    required this.childTable,
    required this.fromColumn,
  });

  final String childTable;
  final String fromColumn;
}

/// Encodes and decodes the JSON payload column of the outbox table.
///
/// Kept next to the store because both sides of the outbox use it.
class OutboxPayloadCodec {
  const OutboxPayloadCodec._();

  static String encode(Map<String, dynamic> payload) => jsonEncode(payload);

  static Map<String, dynamic> decode(String payload) {
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const FormatException('Outbox payload is not a JSON object');
  }
}
