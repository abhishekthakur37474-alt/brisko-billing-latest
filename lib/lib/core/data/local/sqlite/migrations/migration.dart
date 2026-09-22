import 'package:sqflite/sqflite.dart';

/// One irreversible, ordered change to the local database schema or seed data.
///
/// Migrations are how the schema evolves on a terminal that already holds real
/// bills. Dropping and recreating the database would destroy them, so it is never
/// done.
///
/// Rules for adding one:
///
/// * Give it the next unused [version]. Versions are contiguous and start at 1.
/// * Never edit a migration that has shipped. A terminal that already ran it will
///   not run it again, so the edit would silently apply to new installs only.
///   Correct a mistake with a new migration instead.
/// * Keep [migrate] idempotent where it cheaply can be, so a partially applied
///   migration can be retried.
abstract interface class Migration {
  /// Schema version this migration brings the database up to.
  int get version;

  /// Short description, used in migration logs.
  String get description;

  /// Applies the change. Runs inside a transaction owned by the runner, so an
  /// exception rolls the whole migration back.
  Future<void> migrate(DatabaseExecutor db);
}
