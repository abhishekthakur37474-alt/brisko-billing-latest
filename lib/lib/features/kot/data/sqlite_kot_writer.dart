import 'package:sqflite/sqflite.dart';

import '../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../domain/models/kitchen_ticket_draft.dart';
import '../domain/models/kot_item.dart';
import '../domain/models/kot_item_option.dart';

/// Writes the three rows of a kitchen slip, in dependency order.
///
/// Takes a [DatabaseExecutor] rather than owning a connection, so the same code
/// serves both callers: the KOT repository, which opens its own transaction, and
/// settlement, which needs the slip inside the transaction that is already writing
/// the bill. Having one implementation means the two cannot drift into writing the
/// slip differently.
///
/// Foreign keys are enforced, so a line pointing at the wrong slip or at a
/// non-existent bill line aborts the caller's transaction here rather than leaving a
/// half-written slip behind.
class SqliteKotWriter {
  const SqliteKotWriter._();

  /// Tables a slip touches. Watchers on all three are woken once the caller's
  /// transaction commits.
  static const List<String> tables = <String>[
    SqliteTables.kotRecords,
    SqliteTables.kotItems,
    SqliteTables.kotItemOptions,
  ];

  /// Inserts [draft], or updates it in place if the same slip id is already stored.
  ///
  /// Every write is an upsert on `id`. A reused `kotNumber` therefore raises a
  /// constraint error instead of replacing the slip that already holds that number,
  /// and re-writing this same draft lands on its own rows rather than creating a
  /// second slip.
  static Future<void> write(
    DatabaseExecutor db,
    KitchenTicketDraft draft,
  ) async {
    await SqliteUpsert.run(db, SqliteTables.kotRecords, draft.record.toMap());

    for (final KotItem item in draft.items) {
      await SqliteUpsert.run(db, SqliteTables.kotItems, item.toMap());
    }
    for (final KotItemOption option in draft.itemOptions) {
      await SqliteUpsert.run(db, SqliteTables.kotItemOptions, option.toMap());
    }
  }
}
