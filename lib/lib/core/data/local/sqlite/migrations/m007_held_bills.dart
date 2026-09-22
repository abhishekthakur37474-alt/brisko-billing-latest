import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Adds the tables a bill put aside at the counter is stored in.
///
/// ## Why held bills are not orders
///
/// The obvious shortcut would be to write a held bill into `orders` at
/// `OrderStatus.draft` and settle it later by moving the status. That is deliberately
/// not done, for three reasons that all end in the same place.
///
/// A row in `orders` consumes an `orderNumber`, and `orderNumber` is uniquely indexed
/// and allocated by a daily sequence. A bill that is held at 11pm and never resumed
/// would burn a number, and the numbers on the day's bills would have a gap in them
/// that no bill accounts for.
///
/// A row in `orders` is also the thing every report, every customer total and every
/// printed document is derived from. Those queries are positive filters — `status =
/// 'completed'` — so a draft would be excluded today, but the invariant "a row in
/// `orders` is a real bill" is worth more than the table reuse. `order_items` has a
/// `NOT NULL` foreign key to `orders`, so holding a bill there would mean the lines of
/// something that was never sold sit in the same table as the lines that were.
///
/// And a held bill is not a commitment at all. Nothing has been charged, no kitchen
/// slip exists, no stock has moved and no customer record has been created. It is a
/// cart that has been written down. So it gets its own three tables, shaped like the
/// cart rather than like a bill, and the `orders` table stays a record of sales.
///
/// ## Snapshots, not references
///
/// Every name and every price is copied in, exactly as `order_items` does it. A held
/// bill resumed after the menu was repriced, renamed or partly withdrawn has to
/// restore the cart the cashier put aside, not a fresh reading of today's menu.
/// [SqliteTables.heldBillLines] therefore carries `itemNameSnapshot`,
/// `variantNameSnapshot` and `basePriceSnapshotPaise`, and `menuItemId` and
/// `variantId` are nullable back-references with no foreign key — the same treatment
/// `order_items` gives them, and what keeps a held bill readable after a menu row is
/// gone.
///
/// ## Money
///
/// `basePriceSnapshotPaise`, `pricePaise` and `subtotalPaise` are `INTEGER` counts of
/// paise, like every other amount in this schema. Nothing here stores a decimal, so
/// nothing has to parse one back.
///
/// ## `subtotalPaise`, `lineCount` and `itemCount` on the header
///
/// Derivable from the lines, and stored anyway. The held-bills list has to show a
/// total and a count for each entry so the cashier can tell two held bills apart, and
/// reading every line of every held bill to render a list would be the wrong shape of
/// work. They are written once, from the lines being written in the same transaction,
/// and never updated — a held bill is not edited in place.
///
/// ## Notes
///
/// `notes` is on the header only. A cart line has no note field in this build: the
/// note a cashier types belongs to the bill and is entered during settlement, which is
/// where `orders.notes` gets it from. A per-line column here would be schema nothing
/// writes.
class M007HeldBills implements Migration {
  const M007HeldBills();

  @override
  int get version => 7;

  @override
  String get description => 'Held bills, their lines and their options';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    // ----------------------------------------------------------- held bills ---
    // No orderNumber column, and that is the point: nothing here has been sold, so
    // nothing here has a bill number. A number is allocated by settlement, against the
    // settlement's own transaction, if and when this bill is resumed and paid for.
    //
    // customerPhone is the digits the cashier selected, not a customer id and not a
    // foreign key. Holding a bill must not create a customer, so there is nothing to
    // reference; the number is resolved into a customer record by settlement, exactly
    // as a walk-in bill's is.
    //
    // status carries the lifecycle: held, resumed or cancelled. It is a status rather
    // than a physical delete so that "this bill was put aside and then abandoned"
    // stays answerable, which is what makes an unsettled cancellation auditable.
    '''
    CREATE TABLE ${SqliteTables.heldBills} (
      ${SyncColumns.definition},
      orderType TEXT NOT NULL,
      customerPhone TEXT,
      notes TEXT,
      status TEXT NOT NULL,
      subtotalPaise INTEGER NOT NULL DEFAULT 0,
      lineCount INTEGER NOT NULL DEFAULT 0,
      itemCount INTEGER NOT NULL DEFAULT 0
    )
    ''',
    // The one query the held-bills list makes: everything still resumable, oldest
    // first, so the bill that has been waiting longest is at the top.
    '''
    CREATE INDEX idx_held_bills_status
      ON ${SqliteTables.heldBills} (status, isDeleted, createdAt)
    ''',

    // ------------------------------------------------------------ its lines ---
    // cartLineId is the identity the line had in the live cart, kept so that resuming
    // restores the same cart rather than an equivalent one. It matters because the cart
    // keys quantity edits by line id: a resumed line whose id had been regenerated
    // would be a different line to anything holding a reference to the old one.
    //
    // position records the order the lines were added in. `createdAt` plus `rowid`
    // would very nearly reproduce it, as the order tables rely on, but a cart is held
    // as one snapshot and every line shares its instant, so the sequence is written
    // down rather than inferred from an insert order that a future batched write could
    // change.
    '''
    CREATE TABLE ${SqliteTables.heldBillLines} (
      ${SyncColumns.definition},
      heldBillId TEXT NOT NULL,
      cartLineId TEXT NOT NULL,
      position INTEGER NOT NULL,
      menuItemId TEXT,
      variantId TEXT,
      itemNameSnapshot TEXT NOT NULL,
      variantNameSnapshot TEXT,
      basePriceSnapshotPaise INTEGER NOT NULL,
      quantity INTEGER NOT NULL,
      FOREIGN KEY (heldBillId) REFERENCES ${SqliteTables.heldBills} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_held_bill_lines_bill
      ON ${SqliteTables.heldBillLines} (heldBillId, isDeleted, position)
    ''',

    // ---------------------------------------------------------- its options ---
    // optionType is stored because the cart line option carries it, and a resumed line
    // has to be the line that was held — down to how its customisations are grouped on
    // screen. pricePaise is the amount the option added when it was chosen, not what it
    // adds today.
    '''
    CREATE TABLE ${SqliteTables.heldBillLineOptions} (
      ${SyncColumns.definition},
      heldBillLineId TEXT NOT NULL,
      optionId TEXT NOT NULL,
      optionNameSnapshot TEXT NOT NULL,
      optionType TEXT NOT NULL,
      pricePaise INTEGER NOT NULL,
      position INTEGER NOT NULL,
      FOREIGN KEY (heldBillLineId) REFERENCES ${SqliteTables.heldBillLines} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_held_bill_line_options_line
      ON ${SqliteTables.heldBillLineOptions} (heldBillLineId, isDeleted, position)
    ''',
  ];
}
