import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/utils/result.dart';
import '../../domain/repositories/settings_repository.dart';

/// SQLite implementation of [SettingsRepository].
class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository({required this.database});

  final SqliteDatabase database;

  Database get _db => database.database;

  @override
  Future<Result<String?>> readString(String key) {
    return SqliteErrorMapper.guard<String?>(
      () => _readRaw(key),
      context: 'read the setting',
    );
  }

  @override
  Future<Result<int?>> readInt(String key) {
    return SqliteErrorMapper.guard<int?>(() async {
      final String? raw = await _readRaw(key);
      // tryParse rather than parse: a corrupt value should read as absent and
      // fall back to a default, not crash the till at start-up.
      return raw == null ? null : int.tryParse(raw);
    }, context: 'read the setting');
  }

  @override
  Future<Result<bool>> readBool(String key, {bool defaultValue = false}) {
    return SqliteErrorMapper.guard<bool>(() async {
      final String? raw = await _readRaw(key);
      if (raw == null) {
        return defaultValue;
      }
      return raw == 'true';
    }, context: 'read the setting');
  }

  @override
  Future<Result<void>> writeString(String key, String value) =>
      _write(key, value);

  @override
  Future<Result<void>> writeInt(String key, int value) =>
      _write(key, value.toString());

  @override
  Future<Result<void>> writeBool(String key, bool value) =>
      _write(key, value ? 'true' : 'false');

  /// One transaction for the whole form.
  ///
  /// The keys are written inside `Database.transaction`, so a fault partway through
  /// rolls the lot back and the outlet keeps the configuration it had. That is the
  /// difference between a failed save and a half-applied one, and on a tax invoice it
  /// matters: a new address printed above an old GSTIN is a document nobody authored.
  ///
  /// The table change is announced once, after the transaction commits, rather than per
  /// key — so nothing observes the middle of a save.
  @override
  Future<Result<void>> writeAll(Map<String, String?> values) {
    return SqliteErrorMapper.guard<void>(() async {
      if (values.isEmpty) {
        return;
      }

      final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

      await _db.transaction((Transaction txn) async {
        for (final MapEntry<String, String?> entry in values.entries) {
          final String? value = entry.value;
          if (value == null) {
            // A cleared field removes its row. Storing an empty string would leave two
            // representations of "not configured" for every reader to handle.
            await txn.delete(
              SqliteTables.settings,
              where: 'key = ?',
              whereArgs: <Object?>[entry.key],
            );
            continue;
          }

          await SqliteUpsert.run(txn, SqliteTables.settings, <String, Object?>{
            'key': entry.key,
            'value': value,
            'updatedAt': now,
          }, conflictColumn: 'key');
        }
      });

      database.notifyTableChanged(SqliteTables.settings);
    }, context: 'save the settings');
  }

  @override
  Future<Result<Map<String, String?>>> readAll() {
    return SqliteErrorMapper.guard<Map<String, String?>>(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.settings,
        orderBy: 'key ASC',
      );
      return <String, String?>{
        for (final Map<String, Object?> row in rows)
          row['key']! as String: row['value'] as String?,
      };
    }, context: 'read the settings');
  }

  @override
  Future<Result<void>> remove(String key) {
    return SqliteErrorMapper.guard<void>(() async {
      await _db.delete(
        SqliteTables.settings,
        where: 'key = ?',
        whereArgs: <Object?>[key],
      );
      database.notifyTableChanged(SqliteTables.settings);
    }, context: 'remove the setting');
  }

  Future<String?> _readRaw(String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      SqliteTables.settings,
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<Result<void>> _write(String key, String value) {
    return SqliteErrorMapper.guard<void>(() async {
      await SqliteUpsert.run(
        _db,
        SqliteTables.settings,
        <String, Object?>{
          'key': key,
          'value': value,
          'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        // The settings table is keyed by name, not by an entity id.
        conflictColumn: 'key',
      );
      database.notifyTableChanged(SqliteTables.settings);
    }, context: 'save the setting');
  }
}
