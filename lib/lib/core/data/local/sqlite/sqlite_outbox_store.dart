import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../../../utils/result.dart';
import '../../sync/outbox_entry.dart';
import '../../sync/outbox_store.dart';
import 'sqlite_database.dart';
import 'sqlite_error_mapper.dart';
import 'sqlite_local_store.dart';
import 'sqlite_tables.dart';
import 'sqlite_upsert.dart';

/// SQLite-backed implementation of [OutboxStore].
///
/// The queue lives in the same database file as the bills it describes, which is
/// what makes it durable across a restart or a power cut: if the bill survived,
/// so did the record that it still needs uploading.
///
/// Nothing drains this queue yet. The implementation exists now, and is tested,
/// so that adding a backend later is a matter of writing a `RemoteStore` and a
/// `SyncCoordinator` rather than retrofitting durability into the billing module.
class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore({required this.database});

  final SqliteDatabase database;

  final StreamController<int> _pendingCounts =
      StreamController<int>.broadcast();

  Database get _db => database.database;

  @override
  Future<Result<void>> enqueue(OutboxEntry entry) {
    return SqliteErrorMapper.guard<void>(() async {
      await SqliteUpsert.run(_db, SqliteTables.outbox, <String, Object?>{
        'id': entry.id,
        'collection': entry.collection,
        'entityId': entry.entityId,
        'operation': entry.operation.name,
        'payload': OutboxPayloadCodec.encode(entry.payload),
        'queuedAt': entry.queuedAt.toUtc().millisecondsSinceEpoch,
        'attemptCount': entry.attemptCount,
        'lastError': entry.lastError,
      });
      await _publishPendingCount();
    }, context: 'queue the change for upload');
  }

  @override
  Future<Result<List<OutboxEntry>>> dequeueBatch({int limit = 50, int maxAttempts = 8}) {
    return SqliteErrorMapper.guard<List<OutboxEntry>>(() async {
      // Oldest first: replaying out of order could apply a stale update on top
      // of a newer one. Exclude entries that have exceeded maxAttempts to prevent
      // a permanently failing entry from blocking the queue.
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.outbox,
        where: 'attemptCount < ?',
        whereArgs: <Object?>[maxAttempts],
        orderBy: 'queuedAt ASC',
        limit: limit,
      );
      return rows.map(_fromRow).toList(growable: false);
    }, context: 'read the upload queue');
  }

  @override
  Future<Result<void>> markCompleted(String entryId) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.delete(
        SqliteTables.outbox,
        where: 'id = ?',
        whereArgs: <Object?>[entryId],
      );
      await _publishPendingCount();
    }, context: 'clear the uploaded change');
  }

  @override
  Future<Result<void>> markFailed(String entryId, String error) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.rawUpdate(
        'UPDATE ${SqliteTables.outbox} '
        'SET attemptCount = attemptCount + 1, lastError = ? '
        'WHERE id = ?',
        <Object?>[error, entryId],
      );
      await _publishPendingCount();
    }, context: 'record the failed upload');
  }

  @override
  Future<Result<void>> resetAttemptCounts() {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.rawUpdate(
        'UPDATE ${SqliteTables.outbox} SET attemptCount = 0',
      );
    }, context: 'reset attempt counts');
  }

  @override
  Future<Result<void>> clearAll() {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.delete(SqliteTables.outbox);
      await _publishPendingCount();
    }, context: 'clear the upload queue');
  }

  @override
  Future<Result<int>> pendingCount() {
    return SqliteErrorMapper.guard<int>(
      _readPendingCount,
      context: 'count pending uploads',
    );
  }

  @override
  Stream<int> watchPendingCount() => _pendingCounts.stream;

  Future<void> dispose() => _pendingCounts.close();

  Future<int> _readPendingCount() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM ${SqliteTables.outbox}',
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  Future<void> _publishPendingCount() async {
    if (_pendingCounts.isClosed) {
      return;
    }
    _pendingCounts.add(await _readPendingCount());
  }

  static OutboxEntry _fromRow(Map<String, Object?> row) {
    return OutboxEntry(
      id: row['id']! as String,
      collection: row['collection']! as String,
      entityId: row['entityId']! as String,
      operation: OutboxOperation.values.firstWhere(
        (OutboxOperation value) => value.name == row['operation'],
      ),
      payload: OutboxPayloadCodec.decode(row['payload']! as String),
      queuedAt: DateTime.fromMillisecondsSinceEpoch(
        row['queuedAt']! as int,
        isUtc: true,
      ),
      attemptCount: (row['attemptCount'] as int?) ?? 0,
      lastError: row['lastError'] as String?,
    );
  }
}
