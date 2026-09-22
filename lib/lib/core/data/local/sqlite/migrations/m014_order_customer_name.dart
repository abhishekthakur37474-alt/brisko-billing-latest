import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Records the customer name that was taken with a bill, even when no phone was.
///
/// ## Why this column is on the order
///
/// A customer record is keyed by phone. Checkout already requires a name and treats
/// the number as optional, so a dine-in, takeaway, delivery or walk-in bill can
/// carry a name with nothing to file it under. That name was previously discarded at
/// settlement: no phone meant no customer row, and the bill list then read as
/// "Walk-in".
///
/// The name the cashier typed is a fact about *this* bill, the same way
/// `itemNameSnapshot` is a fact about a line. Storing it on the order keeps it
/// without inventing a customer who has no number, and a reprint months later still
/// says who it was for.
///
/// ## Additive
///
/// One `ALTER TABLE ... ADD COLUMN`. No table is rebuilt and no earlier row is
/// rewritten. Bills settled before this column existed keep `NULL`, which is what
/// was known about them: if a name was taken without a phone it was never stored,
/// and if a name was taken with a phone it still lives on the customer record the
/// bill already points at.
class M014OrderCustomerName implements Migration {
  const M014OrderCustomerName();

  @override
  int get version => 14;

  @override
  String get description => 'Customer name snapshot on a settled bill';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await db.execute('''
      ALTER TABLE ${SqliteTables.orders}
        ADD COLUMN customerName TEXT
    ''');
  }
}
