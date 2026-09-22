import 'package:sqflite/sqflite.dart';

import 'migration.dart';

/// Applies pending [Migration]s in version order.
///
/// sqflite already reports the stored schema version through `onCreate` and
/// `onUpgrade`. This runner sits behind both so there is a single ordered list of
/// migrations rather than two divergent code paths: a fresh install simply runs
/// every migration from version 0, and an existing install runs the tail it has
/// not seen. That means a new terminal and an upgraded terminal provably end up
/// with the same schema.
class MigrationRunner {
  MigrationRunner(List<Migration> migrations)
    : _migrations = List<Migration>.unmodifiable(
        migrations.toList()
          ..sort((Migration a, Migration b) => a.version.compareTo(b.version)),
      ) {
    _assertContiguousVersions();
  }

  final List<Migration> _migrations;

  /// Highest version in the list. This is the value handed to sqflite as the
  /// database version, so adding a migration is the only thing needed to trigger
  /// an upgrade.
  int get targetVersion => _migrations.isEmpty ? 1 : _migrations.last.version;

  /// Runs every migration whose version is above [fromVersion] and at or below
  /// [toVersion].
  Future<void> run(
    DatabaseExecutor db, {
    required int fromVersion,
    required int toVersion,
  }) async {
    for (final Migration migration in _migrations) {
      if (migration.version > fromVersion && migration.version <= toVersion) {
        await migration.migrate(db);
      }
    }
  }

  /// Guards against a duplicated or skipped version number, which would leave
  /// some terminals on a different schema from others.
  void _assertContiguousVersions() {
    for (int index = 0; index < _migrations.length; index++) {
      final int expected = index + 1;
      final int actual = _migrations[index].version;
      if (actual != expected) {
        throw StateError(
          'Migration versions must be contiguous starting at 1. '
          'Expected $expected but found $actual '
          '(${_migrations[index].description}).',
        );
      }
    }
  }
}
