import 'package:sqflite/sqflite.dart';

import '../../../utils/result.dart';
import '../../sync/sync_metadata_store.dart';
import 'sqlite_database.dart';
import 'sqlite_error_mapper.dart';
import 'sqlite_tables.dart';
import 'sqlite_upsert.dart';

/// SQLite-backed [SyncMetadataStore], keyed rows in the `sync_metadata` table.
///
/// A tiny key/value store rather than a typed table, for the same reason the
/// settings table is one: the set of bookmarks is small and grows occasionally,
/// and a migration per bookmark would be all cost and no benefit. The keys are
/// private to this class so nothing else can write a value the engine will later
/// misread.
class SqliteSyncMetadataStore implements SyncMetadataStore {
  SqliteSyncMetadataStore({required this.database});

  final SqliteDatabase database;

  Database get _db => database.database;

  static const String _keyHighWaterMark = 'pull.highWaterMarkMillis';
  static const String _keyLastSyncedAt = 'sync.lastSyncedAtMillis';
  static const String _keyBootstrapped = 'bootstrap.completed';

  @override
  Future<Result<DateTime?>> pullHighWaterMark() =>
      _readTimestamp(_keyHighWaterMark);

  @override
  Future<Result<void>> setPullHighWaterMark(DateTime value) =>
      _writeTimestamp(_keyHighWaterMark, value);

  @override
  Future<Result<DateTime?>> lastSyncedAt() => _readTimestamp(_keyLastSyncedAt);

  @override
  Future<Result<void>> setLastSyncedAt(DateTime value) =>
      _writeTimestamp(_keyLastSyncedAt, value);

  @override
  Future<Result<bool>> isBootstrapped() {
    return SqliteErrorMapper.guard<bool>(() async {
      final String? raw = await _read(_keyBootstrapped);
      return raw == 'true';
    }, context: 'read the sync bookmark');
  }

  @override
  Future<Result<void>> markBootstrapped() => _write(_keyBootstrapped, 'true');

  Future<Result<DateTime?>> _readTimestamp(String key) {
    return SqliteErrorMapper.guard<DateTime?>(() async {
      final String? raw = await _read(key);
      if (raw == null) {
        return null;
      }
      final int? millis = int.tryParse(raw);
      return millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }, context: 'read the sync bookmark');
  }

  Future<Result<void>> _writeTimestamp(String key, DateTime value) =>
      _write(key, value.toUtc().millisecondsSinceEpoch.toString());

  Future<String?> _read(String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      SqliteTables.syncMetadata,
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<Result<void>> _write(String key, String value) {
    return SqliteErrorMapper.guard<void>(() async {
      await SqliteUpsert.run(_db, SqliteTables.syncMetadata, <String, Object?>{
        'key': key,
        'value': value,
        'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictColumn: 'key');
    }, context: 'save the sync bookmark');
  }
}
