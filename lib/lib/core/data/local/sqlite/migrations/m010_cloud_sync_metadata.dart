import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Adds the small key/value table the synchronisation engine keeps its bookmarks
/// in.
///
/// ## Why a new table rather than reusing `settings`
///
/// The `settings` table holds operator-facing configuration: the outlet's name,
/// its GSTIN, the printer layout. Synchronisation bookkeeping is a different
/// concern with a different lifecycle — it is written by the sync engine on every
/// cycle, never edited by the operator, and it must not appear in, or be cleared
/// by, the Settings screen's whole-form save. Keeping it in its own table stops
/// the two from writing over each other and keeps the settings save transaction
/// exactly what it was.
///
/// ## What lives here
///
/// Only cursors and markers, never bill data:
///
/// * the high-water mark of the last successful pull, so the next pull asks the
///   cloud only for what changed since;
/// * the timestamp of the last fully successful sync, shown in Settings and used
///   as the "last backup" time;
/// * a flag recording that this terminal has completed its initial bootstrap, so
///   a restore is never attempted over a database that is already in use.
///
/// No cloud credentials are stored here. The provider URL and its client-safe
/// publishable key live in the ordinary settings table like any other
/// configuration; privileged secrets live nowhere in the application at all.
///
/// ## Additive and instant
///
/// One `CREATE TABLE`. No existing table is touched and no row is rewritten, so
/// the upgrade is instant on a terminal with a year of bills on it, and a fresh
/// install reaches the same schema by running this alongside every earlier
/// migration.
class M010CloudSyncMetadata implements Migration {
  const M010CloudSyncMetadata();

  @override
  int get version => 10;

  @override
  String get description => 'Cloud synchronisation bookmarks';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE ${SqliteTables.syncMetadata} (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT,
        updatedAt INTEGER NOT NULL
      )
    ''');
  }
}
