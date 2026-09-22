import 'package:brisko_billing/core/data/local/sqlite/database_factory_initializer.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';
// Re-exports the global `databaseFactory` too, so this covers both the FFI factory and
// the symbol the tests reset.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for the Windows/Linux SQLite start-up failure.
///
/// The bug: on Windows sqflite has no native plugin, so the global
/// [databaseFactory] is never initialised, and the first `openDatabase` call in
/// bootstrap threw "Bad state: databaseFactory not initialized". The fix installs the
/// FFI factory for the platforms that need it, before any database is opened.
///
/// These tests drive the Windows code path explicitly by injecting
/// [DatabaseHostPlatform.requiresFfi], so they prove the behaviour without a Windows
/// machine. The platform detection itself is a thin wrapper over dart:io `Platform`.
void main() {
  group('platform classification', () {
    test(
      'Windows and Linux require the FFI factory; sqflite covers the rest',
      () {
        // The enum is the contract: exactly two classes, and the requiresFfi one is
        // the desktop-without-a-plugin case the bug lived in.
        expect(DatabaseHostPlatform.values, <DatabaseHostPlatform>[
          DatabaseHostPlatform.sqfliteNative,
          DatabaseHostPlatform.requiresFfi,
        ]);
      },
    );
  });

  group('initializeDatabaseFactory', () {
    test(
      'installs the FFI factory on a platform that requires it (Windows/Linux)',
      () {
        var installs = 0;
        final bool installed = initializeDatabaseFactory(
          platform: DatabaseHostPlatform.requiresFfi,
          installFfi: () => installs++,
        );

        expect(
          installed,
          isTrue,
          reason: 'the Windows/Linux path must install a factory',
        );
        expect(
          installs,
          1,
          reason: 'the FFI factory must be installed exactly once',
        );
      },
    );

    test(
      'leaves the native factory untouched on macOS/iOS/Android',
      () {
        var installs = 0;
        final bool installed = initializeDatabaseFactory(
          platform: DatabaseHostPlatform.sqfliteNative,
          installFfi: () => installs++,
        );

        expect(
          installed,
          isFalse,
          reason: 'sqflite-native platforms keep their plugin factory',
        );
        expect(
          installs,
          0,
          reason: 'the FFI factory must not be installed where sqflite has a '
              'native plugin, so existing macOS/iOS behaviour is preserved',
        );
      },
    );
  });

  group('start-up ordering: factory is ready before the first open', () {
    // Proves the actual defect is fixed: with no factory installed, opening throws
    // the exact "databaseFactory not initialized" error; running the Windows-path
    // initializer first makes the same open succeed.

    test(
      'touching the database before the factory is installed throws the '
      'bootstrap error',
      () {
        // Clear any factory a previous test installed, reproducing the pristine
        // Windows launch state where nothing has set databaseFactory yet.
        databaseFactory = null;

        // SqliteDatabase defaults its factory to the global `databaseFactory`, so on a
        // Windows launch the failure surfaces the moment the database is constructed in
        // bootstrap — which is exactly the "databaseFactory not initialized" StateError
        // the reported stack trace ended in, before a single query ran.
        expect(
          SqliteDatabase.new,
          throwsA(
            isA<StateError>().having(
              (StateError e) => e.toString(),
              'message',
              contains('databaseFactory not initialized'),
            ),
          ),
        );
      },
    );

    test(
      'the Windows-path initializer makes the first open succeed',
      () async {
        // Start from the same uninitialised state a Windows launch begins in.
        databaseFactory = null;

        // Bootstrap runs this before it constructs SqliteDatabase and calls open().
        final bool installed = initializeDatabaseFactory(
          platform: DatabaseHostPlatform.requiresFfi,
        );
        expect(installed, isTrue);

        // The same call that used to throw now opens against the installed factory.
        final SqliteDatabase database = SqliteDatabase();
        await database.open(path: SqliteDatabase.inMemoryPath);
        addTearDown(database.close);

        expect(database.isOpen, isTrue);
        expect(
          await database.database.getVersion(),
          SqliteDatabase.schemaVersion,
        );
      },
    );
  });

  // Restore the FFI factory for any test file that runs afterwards in the same
  // process and expects a working database factory.
  tearDownAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
}
