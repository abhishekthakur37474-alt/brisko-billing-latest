import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Records whether a settled bill was paid or left unpaid at the counter.
///
/// ## Why this is on the order
///
/// A bill can be taken and marked unpaid when the customer settles later, or when the
/// cashier is recording a credit sale. Whether the money is in is a fact about *this*
/// bill, printed on the receipt and shown beside it, so it is stored on the order
/// rather than left to be inferred from the payment rows.
///
/// ## Additive
///
/// One `ALTER TABLE ... ADD COLUMN` with a default of `1`, so every bill settled before
/// this column existed reads back as paid, which is what those bills were: until now a
/// bill could only be settled by taking the money.
class M017OrderPaymentStatus implements Migration {
  const M017OrderPaymentStatus();

  @override
  int get version => 17;

  @override
  String get description => 'Paid or unpaid flag on a settled bill';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await db.execute('''
      ALTER TABLE ${SqliteTables.orders}
        ADD COLUMN isPaid INTEGER NOT NULL DEFAULT 1
    ''');
  }
}
