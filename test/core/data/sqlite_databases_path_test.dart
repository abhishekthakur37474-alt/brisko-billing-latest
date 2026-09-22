import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/database_factory_initializer.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_databases_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('resolveWritableDatabasesDirectory', () {
    test('Windows uses LOCALAPPDATA\\BriskoBilling\\databases', () {
      expect(
        resolveWritableDatabasesDirectory(
          environment: const <String, String>{
            'LOCALAPPDATA': r'C:\Users\till\AppData\Local',
            'USERPROFILE': r'C:\Users\till',
          },
          isWindows: true,
        ),
        p.join(r'C:\Users\till\AppData\Local', 'BriskoBilling', 'databases'),
      );
    });

    test('Windows falls back to USERPROFILE when LOCALAPPDATA is missing', () {
      expect(
        resolveWritableDatabasesDirectory(
          environment: const <String, String>{
            'USERPROFILE': r'C:\Users\till',
          },
          isWindows: true,
        ),
        p.join(
          r'C:\Users\till',
          'AppData',
          'Local',
          'BriskoBilling',
          'databases',
        ),
      );
    });

    test('Linux uses XDG_DATA_HOME when set', () {
      expect(
        resolveWritableDatabasesDirectory(
          environment: const <String, String>{
            'XDG_DATA_HOME': '/custom/share',
            'HOME': '/home/till',
          },
          isWindows: false,
        ),
        p.join('/custom/share', 'brisko_billing'),
      );
    });

    test('Linux falls back to ~/.local/share/brisko_billing', () {
      expect(
        resolveWritableDatabasesDirectory(
          environment: const <String, String>{'HOME': '/home/till'},
          isWindows: false,
        ),
        p.join('/home/till', '.local', 'share', 'brisko_billing'),
      );
    });
  });

  group('legacyFfiDatabasesDirectory', () {
    test('is the sqflite_common_ffi default under the working directory', () {
      expect(
        legacyFfiDatabasesDirectory(r'C:\Program Files\Brisko Billing'),
        p.join(
          r'C:\Program Files\Brisko Billing',
          '.dart_tool',
          'sqflite_common_ffi',
          'databases',
        ),
      );
    });
  });

  group('migrateLegacySqliteFiles', () {
    late Directory scratch;

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('brisko_db_path_');
    });

    tearDown(() async {
      if (scratch.existsSync()) {
        await scratch.delete(recursive: true);
      }
    });

    test(
      'copies the database and sidecars when the destination is empty',
      () async {
        final String from = p.join(scratch.path, 'legacy');
        final String to = p.join(scratch.path, 'writable');
        await Directory(from).create(recursive: true);

        await File(p.join(from, SqliteDatabase.fileName)).writeAsBytes(
          const <int>[1, 2, 3, 4],
        );
        await File(p.join(from, '${SqliteDatabase.fileName}-wal')).writeAsBytes(
          const <int>[9],
        );

        await migrateLegacySqliteFiles(fromDirectory: from, toDirectory: to);

        expect(
          await File(p.join(to, SqliteDatabase.fileName)).readAsBytes(),
          <int>[1, 2, 3, 4],
        );
        expect(
          await File(p.join(to, '${SqliteDatabase.fileName}-wal')).readAsBytes(),
          <int>[9],
        );
        // Source is kept so a till never loses its only copy of its bills.
        expect(
          File(p.join(from, SqliteDatabase.fileName)).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'does not overwrite a database that is already in the new location',
      () async {
        final String from = p.join(scratch.path, 'legacy');
        final String to = p.join(scratch.path, 'writable');
        await Directory(from).create(recursive: true);
        await Directory(to).create(recursive: true);

        await File(p.join(from, SqliteDatabase.fileName)).writeAsString('old');
        await File(p.join(to, SqliteDatabase.fileName)).writeAsString('kept');

        await migrateLegacySqliteFiles(fromDirectory: from, toDirectory: to);

        expect(
          await File(p.join(to, SqliteDatabase.fileName)).readAsString(),
          'kept',
        );
      },
    );

    test('does nothing when there is no leftover database', () async {
      final String from = p.join(scratch.path, 'legacy');
      final String to = p.join(scratch.path, 'writable');

      await migrateLegacySqliteFiles(fromDirectory: from, toDirectory: to);

      expect(
        File(p.join(to, SqliteDatabase.fileName)).existsSync(),
        isFalse,
      );
    });
  });

  group('prepareWritableDatabasesPath', () {
    late Directory scratch;
    late String originalPath;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      originalPath = await databaseFactory.getDatabasesPath();
    });

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('brisko_db_prep_');
    });

    tearDown(() async {
      await databaseFactory.setDatabasesPath(originalPath);
      if (scratch.existsSync()) {
        await scratch.delete(recursive: true);
      }
    });

    test('is a no-op on sqflite-native platforms', () async {
      final String? installed = await prepareWritableDatabasesPath(
        platform: DatabaseHostPlatform.sqfliteNative,
        environment: const <String, String>{
          'LOCALAPPDATA': r'C:\Users\till\AppData\Local',
        },
        currentDirectory: scratch.path,
        isWindows: true,
      );

      expect(installed, isNull);
      expect(await databaseFactory.getDatabasesPath(), originalPath);
    });

    test(
      'installs a writable path and migrates a leftover FFI database',
      () async {
        final String localAppData = p.join(scratch.path, 'Local');
        final String cwd = p.join(scratch.path, 'ProgramFiles');
        final String legacyDir = legacyFfiDatabasesDirectory(cwd);
        await Directory(legacyDir).create(recursive: true);
        await File(
          p.join(legacyDir, SqliteDatabase.fileName),
        ).writeAsString('bills');

        final _RecordingFactory recording = _RecordingFactory();
        final String? installed = await prepareWritableDatabasesPath(
          platform: DatabaseHostPlatform.requiresFfi,
          environment: <String, String>{'LOCALAPPDATA': localAppData},
          currentDirectory: cwd,
          isWindows: true,
          databaseFactoryOverride: recording,
        );

        final String expected = p.join(
          localAppData,
          'BriskoBilling',
          'databases',
        );
        expect(installed, expected);
        expect(recording.databasesPath, expected);
        expect(
          await File(p.join(expected, SqliteDatabase.fileName)).readAsString(),
          'bills',
        );
      },
    );
  });
}

/// Captures [setDatabasesPath] without touching the process-wide FFI factory.
class _RecordingFactory implements DatabaseFactory {
  String? databasesPath;

  @override
  Future<String> getDatabasesPath() async => databasesPath ?? '';

  @override
  Future<void> setDatabasesPath(String path) async {
    databasesPath = path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
