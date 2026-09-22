import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Adds the table a refunded bill's returned money is recorded in.
///
/// ## Why a refund is a row of its own
///
/// The three shortcuts all corrupt the record, so none is taken.
///
/// Flipping the original tender's `status` to `refunded` would be the smallest edit. It is
/// also the one that destroys the evidence: the row saying "₹210 arrived in cash at
/// 1:30pm" would be overwritten by a row saying it did not, and the till reconciliation
/// for that shift would stop adding up. The money genuinely did arrive; something else
/// happened afterwards.
///
/// Rewriting `orders.totalAmountPaise` down to zero would make the bill disagree with the
/// receipt the customer is holding, with its own lines and with the kitchen slip.
///
/// Moving the order to `cancelled` would take the whole sale out of gross takings, which
/// is the figure an auditor reconciles against the day's receipts. A sale that happened
/// and was later reversed is two facts, not the absence of one.
///
/// So the sale is left exactly as it was settled, and the reversal is written beside it.
/// Gross sales stay auditable, net sales become gross minus this table, and the payment
/// mix reconciles as completed tenders minus completed refunds.
///
/// ## The unique index is the whole idempotency story
///
/// `idx_refunds_order` is UNIQUE on `orderId` for rows that are not soft-deleted. That is
/// not an optimisation, it is the rule "a bill can be refunded once" expressed where it
/// cannot be forgotten. The repository re-reads the bill inside its transaction and
/// refuses a second refund with a message the cashier can act on; this index is what
/// still holds if that check is ever removed, reordered or raced. The same shape as
/// `idx_order_inventory_deductions_order` in `M006RecipesAndStockDeduction`, for the same
/// reason.
///
/// It is a partial index (`WHERE isDeleted = 0`) because deletion is soft everywhere in
/// this schema. Without the clause, a refund row that was ever soft-deleted would block
/// the bill from being refunded again forever.
///
/// This index is also what pins the feature to whole-bill refunds. Refunding two lines of
/// a five line bill would need two rows against one order, so partial refunds are a
/// schema change and a deliberate later step rather than something that could arrive by
/// accident.
///
/// ## Snapshots, not lookups
///
/// `orderNumberSnapshot` is copied in, exactly as `order_inventory_deductions` copies it.
/// A refund has to be able to name the bill it reversed without joining to a table it is
/// only loosely about, and a list of the day's refunds must read correctly whatever
/// happens to the order row later.
///
/// `paymentMethod` is a snapshot too, and it is the method the money went back by. It is
/// stored rather than read through `paymentId` because the payment report groups refunds
/// by method and must not have to join to `payments` to do it. Its values are the
/// existing four on `PaymentMethod`; no tender type is added for refunds, because a
/// refund is not a way of paying.
///
/// ## Money
///
/// `amountPaise` is an `INTEGER` count of paise like every other amount in this schema,
/// and it is stored **positive**. A negative amount would let the sign carry the meaning,
/// and then any query that forgot to filter by table would silently net a refund against
/// a sale. The direction is the table.
///
/// ## `paymentId`
///
/// `NOT NULL` with a foreign key: a refund reverses a specific tender that specifically
/// arrived. There is nothing to reverse on a bill that was never paid, and the repository
/// refuses that case rather than writing a row pointing nowhere. `ON DELETE RESTRICT`
/// matches the rest of the schema, so the tender a refund names cannot be removed from
/// under it.
class M008Refunds implements Migration {
  const M008Refunds();

  @override
  int get version => 8;

  @override
  String get description => 'Refunds and payment reversal';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    // -------------------------------------------------------------- refunds ---
    // status carries the same vocabulary as a tender's, from `PaymentStatus`, and for the
    // same reason: handing cash back is immediate, but a UPI or card reversal is
    // requested and then confirmed. Only `completed` is written today. Reusing the enum
    // rather than inventing a parallel one is what keeps "money that has actually moved"
    // a single idea across payments and refunds — the reports filter both on the same
    // token.
    //
    // reason is the operator's free text, nullable. It is a note on the reversal, not a
    // closed set: an outlet's reasons are its own and enumerating them here would be
    // inventing the outlet's process.
    '''
    CREATE TABLE ${SqliteTables.refunds} (
      ${SyncColumns.definition},
      orderId TEXT NOT NULL,
      paymentId TEXT NOT NULL,
      orderNumberSnapshot TEXT NOT NULL,
      paymentMethod TEXT NOT NULL,
      amountPaise INTEGER NOT NULL,
      reason TEXT,
      status TEXT NOT NULL,
      FOREIGN KEY (orderId) REFERENCES ${SqliteTables.orders} (id)
        ON DELETE RESTRICT,
      FOREIGN KEY (paymentId) REFERENCES ${SqliteTables.payments} (id)
        ON DELETE RESTRICT
    )
    ''',
    // The idempotency key, and the constraint that makes two simultaneous refunds resolve
    // to one winner even if the repository's own guard were removed. Partial, because
    // deletion is soft: see the class comment.
    '''
    CREATE UNIQUE INDEX idx_refunds_order
      ON ${SqliteTables.refunds} (orderId)
      WHERE ${SyncColumns.isDeleted} = 0
    ''',
    // Answers "what did this bill's tender have taken back off it", which is what the
    // bill detail screen asks before offering a refund.
    '''
    CREATE INDEX idx_refunds_payment
      ON ${SqliteTables.refunds} (paymentId, ${SyncColumns.isDeleted})
    ''',
    // Drives the reports: refunds in a date range, by status, oldest first.
    '''
    CREATE INDEX idx_refunds_status
      ON ${SqliteTables.refunds} (status, ${SyncColumns.isDeleted}, ${SyncColumns.createdAt})
    ''',
    // The payment breakdown groups by method over a range.
    '''
    CREATE INDEX idx_refunds_method
      ON ${SqliteTables.refunds} (paymentMethod, ${SyncColumns.createdAt})
    ''',
  ];
}
