import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'migrations/m001_initial_schema.dart';
import 'migrations/m002_seed_menu.dart';
import 'migrations/m003_seed_menu_products.dart';
import 'migrations/m004_scoped_menu_options.dart';
import 'migrations/m005_kot_order_snapshots.dart';
import 'migrations/m006_recipes_and_stock_deduction.dart';
import 'migrations/m007_held_bills.dart';
import 'migrations/m008_refunds.dart';
import 'migrations/m009_bill_tax_and_discount.dart';
import 'migrations/m010_cloud_sync_metadata.dart';
import 'migrations/m011_seed_new_combos.dart';
import 'migrations/m012_expenses_and_cancellation.dart';
import 'migrations/m013_rtdb_resync.dart';
import 'migrations/m014_order_customer_name.dart';
import 'migrations/m015_spec_menu.dart';
import 'migrations/m016_order_customer_address.dart';
import 'migrations/migration.dart';
import 'migrations/migration_runner.dart';

/// Owns the local SQLite database: opening it, migrating it, and announcing when
/// a table changes.
///
/// This is the only class that knows a file path or a schema version. Everything
/// above it works through `LocalStore` and the repositories, so SQLite could be
/// replaced without touching a feature.
class SqliteDatabase {
  SqliteDatabase({DatabaseFactory? factory})
    : _factory = factory ?? databaseFactory;

  /// The ordered migration list. Adding an entry here is the only step needed to
  /// evolve the schema; the database version is derived from it.
  static final MigrationRunner _runner = MigrationRunner(<Migration>[
    const M001InitialSchema(),
    const M002SeedMenu(),
    const M003SeedMenuProducts(),
    const M004ScopedMenuOptions(),
    const M005KotOrderSnapshots(),
    const M006RecipesAndStockDeduction(),
    const M007HeldBills(),
    const M008Refunds(),
    const M009BillTaxAndDiscount(),
    const M010CloudSyncMetadata(),
    const M011SeedNewCombos(),
    const M012ExpensesAndCancellation(),
    const M013RtdbResync(),
    const M014OrderCustomerName(),
    const M015SpecMenu(),
    const M016OrderCustomerAddress(),
  ]);

  /// File name of the database inside the platform's databases directory.
  static const String fileName = 'brisko_billing.db';

  /// Passed to [open] to keep the database in memory. Used by tests.
  static const String inMemoryPath = inMemoryDatabasePath;

  final DatabaseFactory _factory;

  Database? _database;

  final StreamController<String> _tableChanges =
      StreamController<String>.broadcast();

  /// Schema version this build expects.
  static int get schemaVersion => _runner.targetVersion;

  /// The open database handle.
  ///
  /// Throws [StateError] if accessed before [open]. Deliberately not lazily
  /// opening: start-up ordering should be explicit in the bootstrap rather than an
  /// accident of whichever query ran first.
  Database get database {
    final Database? db = _database;
    if (db == null) {
      throw StateError('SqliteDatabase.open() must be awaited before use.');
    }
    return db;
  }

  bool get isOpen => _database != null;

  /// Emits a table name whenever rows in it are inserted, updated or soft-deleted
  /// through a store or repository.
  ///
  /// SQLite has no built-in change feed that sqflite surfaces, so writes announce
  /// themselves here. This is what lets `LocalStore.watchAll` push updates to the
  /// UI instead of the UI polling.
  Stream<String> get tableChanges => _tableChanges.stream;

  /// Opens the database, creating and migrating it as needed.
  ///
  /// Pass [path] to override the location; the default is [fileName] inside the
  /// platform databases directory. Pass [inMemoryPath] for a throwaway database.
  Future<Database> open({String? path}) async {
    if (_database != null) {
      return _database!;
    }

    final String resolvedPath =
        path ?? p.join(await _factory.getDatabasesPath(), fileName);

    final Database db = await _factory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      ),
    );

    _database = db;
    return db;
  }

  /// Announces that [table] changed, waking any active `watchAll` subscriber.
  void notifyTableChanged(String table) {
    if (!_tableChanges.isClosed) {
      _tableChanges.add(table);
    }
  }

  /// Announces several tables at once, for a write that spanned them.
  void notifyTablesChanged(Iterable<String> tables) {
    for (final String table in tables) {
      notifyTableChanged(table);
    }
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    await _tableChanges.close();
  }

  static Future<void> _onConfigure(Database db) async {
    // Off by default in SQLite. Without it the schema's referential constraints
    // are decorative, and an order item could reference a non-existent order.
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Fresh install: run every migration from zero so a new terminal follows the
  /// same path as an upgraded one.
  static Future<void> _onCreate(Database db, int version) async {
    await db.transaction((Transaction txn) async {
      await _runner.run(txn, fromVersion: 0, toVersion: version);
    });
  }

  /// Existing install: run only the migrations it has not seen. The database is
  /// never dropped, because it holds real bills.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    await db.transaction((Transaction txn) async {
      await _runner.run(txn, fromVersion: oldVersion, toVersion: newVersion);
    });
  }

  /// Refuse to open a database newer than this build understands.
  ///
  /// The alternative that sqflite offers, `onDowngradeDelete`, would erase the
  /// outlet's bills. Failing to start is recoverable; silent data loss is not.
  static Future<void> _onDowngrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    throw StateError(
      'The local database is at version $oldVersion but this build of '
      'Brisko Billing expects version $newVersion. Install the newer build '
      'again. The database has not been modified.',
    );
  }
}
