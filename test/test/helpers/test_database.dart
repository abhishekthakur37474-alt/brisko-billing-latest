import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Test support for the SQLite layer.
///
/// Tests run in the Dart VM, where sqflite's platform plugin does not exist, so the
/// FFI implementation is installed instead. It is the same SQLite engine, driven
/// through the same sqflite API, which means these tests exercise the real schema
/// and the real queries rather than a stub.
class TestDatabase {
  const TestDatabase._();

  /// Installs the FFI factory. Call once per test file, from `setUpAll`.
  static void register() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  /// Opens a fresh in-memory database, fully migrated.
  ///
  /// In-memory keeps tests isolated and fast, and guarantees no test can read
  /// leftover state from another. Use [openOnDisk] where the test is specifically
  /// about persistence across a reopen.
  static Future<SqliteDatabase> openInMemory() async {
    final SqliteDatabase database = SqliteDatabase(factory: databaseFactoryFfi);
    await database.open(path: SqliteDatabase.inMemoryPath);
    return database;
  }

  /// Opens a database at [path], migrating it if needed.
  ///
  /// Used to prove that closing and reopening preserves data, which an in-memory
  /// database cannot demonstrate.
  static Future<SqliteDatabase> openOnDisk(String path) async {
    final SqliteDatabase database = SqliteDatabase(factory: databaseFactoryFfi);
    await database.open(path: path);
    return database;
  }
}
