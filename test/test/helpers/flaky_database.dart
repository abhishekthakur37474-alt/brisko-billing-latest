import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A [DatabaseFactory] whose databases can be made to fail a write part way through.
///
/// ## Why this exists
///
/// "A hold either commits whole or rolls back to nothing" is a claim about a transaction,
/// and the only way to hold it is to make a write inside one fail after some rows have
/// already landed. A test that merely holds a bill successfully would pass just as happily
/// against a repository that wrote its rows outside a transaction, and that repository
/// would leave half a held bill behind the first time the disk hiccuped.
///
/// So the held-bill repository is driven through this factory, [failAfterWrites] is set to
/// the number of writes that should succeed, and the test asserts that the failure left no
/// rows behind and that the same draft goes through once the fault clears.
///
/// ## How it wraps
///
/// [SqliteDatabase] takes a factory, so substituting this one needs no production hook. Only
/// writes are counted and failed — reads and schema creation pass straight through — and
/// the count spans both the database and the [Transaction] it hands a callback, because a
/// hold does its work inside one transaction. The injected fault is a plain [Exception], so
/// it surfaces as an unexpected failure rather than being mistaken for a rule violation.
class FlakyDatabaseFactory implements DatabaseFactory {
  FlakyDatabaseFactory([DatabaseFactory? inner])
    : _inner = inner ?? databaseFactoryFfi;

  final DatabaseFactory _inner;

  /// Writes to allow before the next one is refused, or `null` to allow them all.
  ///
  /// Counted across the database and any transaction opened on it, so `failAfterWrites =
  /// 1` lets the header land and refuses the first line after it.
  int? failAfterWrites;

  int _writes = 0;

  /// Forgets the writes counted so far. Leaves [failAfterWrites] as it was set.
  void reset() => _writes = 0;

  /// Stops failing writes, so a database committed nothing can be read back or reused.
  void allowAllWrites() => failAfterWrites = null;

  /// Records a write and throws once the allowance is spent.
  ///
  /// Throwing before the inner call runs is what leaves the failing row unwritten while the
  /// rows before it stay, so the rollback the test checks for is a real rollback.
  void _guardWrite() {
    final int? limit = failAfterWrites;
    if (limit != null && _writes >= limit) {
      throw Exception('Injected write failure after $limit writes.');
    }
    _writes++;
  }

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    final Database database = await _inner.openDatabase(path, options: options);
    return _FlakyDatabase(database, _guardWrite);
  }

  @override
  Future<void> deleteDatabase(String path) => _inner.deleteDatabase(path);

  @override
  Future<bool> databaseExists(String path) => _inner.databaseExists(path);

  @override
  Future<String> getDatabasesPath() => _inner.getDatabasesPath();

  @override
  Future<void> setDatabasesPath(String path) => _inner.setDatabasesPath(path);

  @override
  Future<Uint8List> readDatabaseBytes(String path) =>
      _inner.readDatabaseBytes(path);

  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) =>
      _inner.writeDatabaseBytes(path, bytes);
}

/// A [Database] that runs [_guardWrite] before each write, then delegates.
///
/// Only the members the application actually calls are implemented; anything else reaches
/// [noSuchMethod] and throws, so a write route that slipped past the guard would be caught
/// here rather than committing unfailably.
class _FlakyDatabase implements Database {
  _FlakyDatabase(this._inner, this._guardWrite);

  final Database _inner;
  final void Function() _guardWrite;

  // ------------------------------------------------------------------ reading ---

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _inner.rawQuery(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => _inner.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  // ------------------------------------------------------------------ writing ---

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.execute(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawInsert(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _guardWrite();
    return _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawUpdate(sql, arguments);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _guardWrite();
    return _inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawDelete(sql, arguments);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    _guardWrite();
    return _inner.delete(table, where: where, whereArgs: whereArgs);
  }

  /// Runs [action] against a transaction whose writes are guarded too.
  ///
  /// A hold does all of its work inside one transaction, so counting only the database's
  /// own writes would never fail one. The inner transaction is wrapped so the guard spans
  /// the statements the callback runs, and a throw inside it rolls the whole thing back.
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    return _inner.transaction<T>(
      (Transaction txn) => action(_FlakyTransaction(txn, _guardWrite)),
      exclusive: exclusive,
    );
  }

  // ------------------------------------------------------------------ handles ---

  @override
  Database get database => this;

  @override
  String get path => _inner.path;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Future<void> close() => _inner.close();

  @override
  Batch batch() => _inner.batch();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [Transaction] that runs [_guardWrite] before each write, then delegates.
class _FlakyTransaction implements Transaction {
  _FlakyTransaction(this._inner, this._guardWrite);

  final Transaction _inner;
  final void Function() _guardWrite;

  // ------------------------------------------------------------------ reading ---

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _inner.rawQuery(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => _inner.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  // ------------------------------------------------------------------ writing ---

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.execute(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawInsert(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _guardWrite();
    return _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawUpdate(sql, arguments);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _guardWrite();
    return _inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) {
    _guardWrite();
    return _inner.rawDelete(sql, arguments);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    _guardWrite();
    return _inner.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Batch batch() => _inner.batch();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
