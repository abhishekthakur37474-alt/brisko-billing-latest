import 'package:sqflite/sqflite.dart';

import '../../../../core/data/sync/sync_state.dart';
import '../../../core/data/local/sqlite/row.dart';
import '../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../core/utils/entity_id.dart';
import '../domain/models/customer.dart';
import '../domain/models/customer_phone.dart';

/// Finds or creates the customer for a phone number, on a caller's executor.
///
/// Takes a [DatabaseExecutor] rather than owning a connection, for the same reason
/// `SqliteKotWriter` does: two callers need this and they need it in different
/// transactions. The customer repository calls it in a transaction of its own, and
/// settlement calls it inside the transaction that is already writing the bill.
///
/// ## Why settlement resolves the customer inside its own transaction
///
/// Resolving beforehand, in the repository's transaction, commits the customer row
/// first. If the bill then failed to write, the outlet would be left with a customer
/// who never ordered anything — a record of a sale that did not happen. Doing it here
/// means the customer and the bill land together or not at all.
///
/// Having one implementation rather than two also means the phone number is stored the
/// same way whichever door it comes through, so the counter cannot end up with
/// `9876543210` from checkout and `+919876543210` from somewhere else.
///
/// ## Why the phone number arrives already normalised
///
/// Because validation cannot happen in here. Inside a sqflite transaction, every future
/// that is awaited has to be a database operation: awaiting anything else yields the
/// transaction's turn to code that cannot proceed until it commits, and the two wait for
/// each other. An `async` method that validates first and returns early without touching
/// the database is exactly that kind of await, and it deadlocks settlement.
///
/// So [resolve] takes a number that has already been through
/// [CustomerPhone.normalise], and the very first thing it does is a query. Callers
/// normalise before they open their transaction, which is where a bad number should be
/// refused anyway — before anything has been written.
class SqliteCustomerWriter {
  const SqliteCustomerWriter._();

  /// The id of the customer for [normalisedPhone], creating the record if it is new.
  ///
  /// [normalisedPhone] must be the stored form, as returned by
  /// [CustomerPhone.normalise]. A walk-in has no number and must not reach here: the
  /// caller writes the bill with no customer reference instead.
  ///
  /// Idempotent. Called twice with the same number it returns the same id and inserts
  /// nothing the second time, which is what makes a retried settlement safe.
  static Future<String> resolve(
    DatabaseExecutor db,
    String normalisedPhone, {
    String? name,
  }) async {
    final List<Map<String, Object?>> existing = await db.query(
      SqliteTables.customers,
      columns: <String>[SyncColumns.id],
      where: 'phone = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[normalisedPhone],
      // Oldest first, so a duplicate created by an earlier build never shadows the
      // record that carries the longer history.
      orderBy: '${SyncColumns.createdAt} ASC',
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final String existingId = existing.first[SyncColumns.id]! as String;
      final String? cleanName = _cleaned(name);
      if (cleanName != null) {
        final DateTime now = DateTime.now().toUtc();
        await db.update(
          SqliteTables.customers,
          <String, Object?>{
            'name': cleanName,
            SyncColumns.updatedAt: SqliteValue.fromDateTime(now),
            SyncColumns.syncState: SyncState.pending.name,
          },
          where: '${SyncColumns.id} = ?',
          whereArgs: <Object?>[existingId],
        );
      }
      return existingId;
    }

    final DateTime now = DateTime.now().toUtc();
    final Customer created = Customer(
      id: EntityId.generate(prefix: 'cus'),
      name: _cleaned(name),
      phone: normalisedPhone,
      createdAt: now,
      updatedAt: now,
    );

    await db.insert(SqliteTables.customers, created.toMap());
    return created.id;
  }

  static String? _cleaned(String? name) {
    final String? trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
