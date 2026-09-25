import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Records the delivery address taken with a bill.
///
/// ## Why this column is on the order
///
/// A delivery has to reach a door. The address the cashier typed is a fact about
/// *this* bill, the same way `customerName` is: it was true at settlement, it is
/// printed on the receipt and the kitchen slip, and a reprint months later still
/// has to say where the order went. Storing it on the order keeps it without
/// inventing an address book, and the same `toMap` that already syncs the bill
/// to Realtime Database carries the address with it.
///
/// ## Additive
///
/// One `ALTER TABLE ... ADD COLUMN`. No table is rebuilt and no earlier row is
/// rewritten. Bills settled before this column existed keep `NULL`, which is
/// what was known about them: no address was collected.
class M016OrderCustomerAddress implements Migration {
  const M016OrderCustomerAddress();

  @override
  int get version => 16;

  @override
  String get description => 'Delivery address snapshot on a settled bill';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    await db.execute('''
      ALTER TABLE ${SqliteTables.orders}
        ADD COLUMN customerAddress TEXT
    ''');
  }
}
