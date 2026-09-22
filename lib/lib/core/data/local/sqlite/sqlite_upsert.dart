import 'package:sqflite/sqflite.dart';

import 'sqlite_tables.dart';

/// Inserts a row, or updates it when one with the same key already exists.
///
/// ## Why not `ConflictAlgorithm.replace`
///
/// sqflite's `replace` maps to SQLite's `INSERT OR REPLACE`, which resolves a
/// conflict on *any* unique constraint by deleting the offending row and inserting
/// the new one. On a table whose only unique key is the primary key that is
/// harmless. On `orders` it is dangerous: `orderNumber` is also unique, so
/// inserting a new order that reused an existing number would silently delete a
/// real, settled bill. The same hazard applies to `kot_records.kotNumber`.
///
/// This helper instead targets one conflict column explicitly with
/// `ON CONFLICT (...) DO UPDATE`. Re-saving a record by its own id still updates in
/// place, which is what a repository's `save` needs, but a collision on any *other*
/// unique constraint now raises a constraint error that the error mapper turns into
/// a `ValidationFailure`. Losing a bill is not an acceptable failure mode; refusing
/// the write is.
class SqliteUpsert {
  const SqliteUpsert._();

  /// Writes [values] into [table], treating [conflictColumn] as the identity.
  ///
  /// [conflictColumn] must be the primary key or carry a unique index, otherwise
  /// SQLite cannot use it to resolve the conflict.
  static Future<void> run(
    DatabaseExecutor db,
    String table,
    Map<String, Object?> values, {
    String conflictColumn = SyncColumns.id,
  }) async {
    final List<String> columns = values.keys.toList(growable: false);
    if (columns.isEmpty) {
      return;
    }

    final String columnList = columns.join(', ');
    final String placeholders = List<String>.filled(
      columns.length,
      '?',
    ).join(', ');

    // The identity column is never reassigned; it is what matched.
    final List<String> assignments = columns
        .where((String column) => column != conflictColumn)
        .map((String column) => '$column = excluded.$column')
        .toList(growable: false);

    final String resolution = assignments.isEmpty
        ? 'DO NOTHING'
        : 'DO UPDATE SET ${assignments.join(', ')}';

    await db.rawInsert(
      'INSERT INTO $table ($columnList) VALUES ($placeholders) '
      'ON CONFLICT ($conflictColumn) $resolution',
      columns.map((String column) => values[column]).toList(growable: false),
    );
  }
}
