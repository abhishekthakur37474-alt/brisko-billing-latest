import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A [DatabaseFactory] that hands out databases which count the statements run through
/// them.
///
/// ## Why this exists
///
/// "Avoid N+1 queries" is a claim about how many statements a report runs, and the only
/// way to hold it is to count them. A test that merely checks a report's numbers would
/// pass just as happily against an implementation that read every bill in a separate
/// query, and that implementation would be discovered on a busy Saturday rather than here.
///
/// So the reports repository is driven through this factory, and the test asserts that
/// reporting on sixty bills runs the same number of statements as reporting on one.
///
/// ## How it wraps
///
/// [SqliteDatabase] takes a factory, so substituting this one needs no production hook. The
/// migration callbacks are handed the *inner* database by sqflite, so schema creation is
/// not counted, and [reset] clears whatever the test's own arrangement ran.
class CountingDatabaseFactory implements DatabaseFactory {
  CountingDatabaseFactory([DatabaseFactory? inner])
    : _inner = inner ?? databaseFactoryFfi;

  final DatabaseFactory _inner;

  final List<String> _statements = <String>[];

  /// Every statement run through a database from this factory, oldest first.
  ///
  /// A table name for the typed helpers, the SQL itself for the raw ones. Exposed so a
  /// failure message can say what actually ran rather than only how many things did.
  List<String> get statements => List<String>.unmodifiable(_statements);

  /// Number of statements run since the last [reset].
  int get count => _statements.length;

  /// Forgets everything counted so far.
  void reset() => _statements.clear();

  void _record(String statement) => _statements.add(statement);

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    final Database database = await _inner.openDatabase(path, options: options);
    return _CountingDatabase(database, _record);
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

/// A [Database] that reports each statement before delegating it.
///
/// Only the members the application actually calls are implemented. Anything else on the
/// interface reaches [noSuchMethod] and throws, which is deliberate: a silent no-op
/// forwarder would let a future call slip past uncounted, and the point of this class is
/// that nothing slips past.
class _CountingDatabase implements Database {
  _CountingDatabase(this._inner, this._record);

  final Database _inner;

  final void Function(String statement) _record;

  // ------------------------------------------------------------------ reading ---

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    _record(sql);
    return _inner.rawQuery(sql, arguments);
  }

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
  }) {
    _record('SELECT FROM $table');
    return _inner.query(
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
  }

  // ------------------------------------------------------------------ writing ---

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    _record(sql);
    return _inner.execute(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    _record(sql);
    return _inner.rawInsert(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _record('INSERT INTO $table');
    return _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) {
    _record(sql);
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
    _record('UPDATE $table');
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
    _record(sql);
    return _inner.rawDelete(sql, arguments);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    _record('DELETE FROM $table');
    return _inner.delete(table, where: where, whereArgs: whereArgs);
  }

  /// Runs [action] against the inner database.
  ///
  /// The transaction body is handed the real `Transaction`, so statements inside it are
  /// not counted. That is the behaviour the reports test wants: it counts the reads a
  /// report performs, and a report never opens a transaction.
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    _record('BEGIN');
    return _inner.transaction<T>(action, exclusive: exclusive);
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

  /// Anything on the interface the application does not call.
  ///
  /// Reached only through the forwarders Dart generates for unimplemented members, and it
  /// throws, so an uncounted route into the database cannot appear unnoticed.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
