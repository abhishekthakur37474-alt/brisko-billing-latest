import 'package:brisko_billing/core/data/local/sqlite/migrations/migration.dart';
import 'package:brisko_billing/core/data/local/sqlite/migrations/migration_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

/// Records that it ran, without touching a database.
class _RecordingMigration implements Migration {
  _RecordingMigration(this.version);

  @override
  final int version;

  @override
  String get description => 'recording $version';

  bool didRun = false;

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    didRun = true;
  }
}

void main() {
  group('MigrationRunner', () {
    test('derives the target version from the highest migration', () {
      final MigrationRunner runner = MigrationRunner(<Migration>[
        _RecordingMigration(1),
        _RecordingMigration(2),
        _RecordingMigration(3),
      ]);

      expect(runner.targetVersion, 3);
    });

    test('sorts migrations regardless of the order supplied', () {
      final MigrationRunner runner = MigrationRunner(<Migration>[
        _RecordingMigration(2),
        _RecordingMigration(1),
      ]);

      expect(runner.targetVersion, 2);
    });

    test('rejects a duplicated version', () {
      expect(
        () => MigrationRunner(<Migration>[
          _RecordingMigration(1),
          _RecordingMigration(1),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a gap in versions', () {
      // A skipped number would leave some terminals on a different schema.
      expect(
        () => MigrationRunner(<Migration>[
          _RecordingMigration(1),
          _RecordingMigration(3),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('a fresh install runs every migration', () async {
      final List<_RecordingMigration> migrations = <_RecordingMigration>[
        _RecordingMigration(1),
        _RecordingMigration(2),
      ];
      final MigrationRunner runner = MigrationRunner(migrations);

      await runner.run(_NullExecutor(), fromVersion: 0, toVersion: 2);

      expect(migrations.every((_RecordingMigration m) => m.didRun), isTrue);
    });

    test('an upgrade runs only the unseen migrations', () async {
      final _RecordingMigration first = _RecordingMigration(1);
      final _RecordingMigration second = _RecordingMigration(2);
      final MigrationRunner runner = MigrationRunner(<Migration>[
        first,
        second,
      ]);

      await runner.run(_NullExecutor(), fromVersion: 1, toVersion: 2);

      expect(first.didRun, isFalse, reason: 'already applied');
      expect(second.didRun, isTrue);
    });
  });
}

/// Stands in for a database executor. The recording migrations never touch it.
class _NullExecutor implements DatabaseExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'Recording migrations must not touch the database',
  );
}
