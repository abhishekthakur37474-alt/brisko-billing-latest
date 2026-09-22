import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Records the GST rate and the discount rule a bill was settled with.
///
/// ## What was already there, and why it was not enough
///
/// `orders` has carried `discountAmountPaise` and `taxAmountPaise` since
/// `M001InitialSchema`, and settlement has always written both — as zero, because nothing
/// produced either. Those two columns are reused rather than duplicated: the *amounts*
/// need no schema change at all.
///
/// What is missing is the *why*. An order that says `taxAmountPaise = 16200` cannot say
/// whether that was 18% of ₹900 or 16.2% of ₹1,000, and one that says
/// `discountAmountPaise = 10000` cannot say whether the customer was given ₹100 off or ten
/// percent. Both facts are on the bill the customer is holding, so both have to be
/// reproducible from the row. Three columns are added for that, and no amount column is
/// touched.
///
/// ## Why a bill keeps its own rate
///
/// The GST rate is configured in Settings, and settings change. If a reprint or a report
/// read today's rate, then the day the outlet moved from 5% to 18% every bill it had ever
/// issued would silently restate itself, the reprinted copy would disagree with the paper
/// in the customer's hand, and last quarter's return would stop matching the takings it
/// was filed from.
///
/// So the rate in force is copied onto the order at settlement and never read from settings
/// again. `taxRateBasisPoints` is that copy. It is the same arrangement `itemNameSnapshot`
/// and `unitPricePaise` already have on `order_items`, for the same reason.
///
/// ## Why basis points
///
/// 10000 is 100%, so 5% is `500`. An `INTEGER`, like every other number in this schema that
/// takes part in an amount calculation: 18% has no exact binary representation, and a rate
/// stored as a `REAL` would multiply a subtotal into a figure a paisa away from the one on
/// the paper. See `GstRate`.
///
/// ## Why the discount value shares one column
///
/// `discountType` names the rule — `percentage` or `amount`, the `BillDiscountType` enum
/// names — and `discountValue` holds its magnitude in hundredths: basis points for a
/// percentage, paise for a flat sum. Hundredths either way, so one `INTEGER` carries both
/// and is unambiguous in the company of the type beside it. Two columns, one of which is
/// always null, would be a wider row and one more pair of values that could disagree.
///
/// `discountValue` is deliberately **not** an amount and is deliberately not named `Paise`:
/// for a percentage it is not money at all, and a column called `discountValuePaise`
/// holding `1000` to mean ten percent would be read as ₹10 by the first query that came
/// along.
///
/// ## Additive, with defaults that make an old bill read correctly
///
/// Three `ALTER TABLE ... ADD COLUMN`s and nothing else. No table is rebuilt, no row is
/// rewritten, and no earlier migration is edited.
///
/// Every bill settled before this migration was settled with no discount and no tax — that
/// is what `BillTotals` produced — so `taxRateBasisPoints DEFAULT 0` states the truth about
/// those rows rather than guessing at it. A rate of zero is not a missing value standing in
/// for an unknown one; it is what those bills were charged.
///
/// `discountType` is nullable with no default, because there is a real difference between
/// "no bill-level discount rule was recorded" and "a rule was recorded and it took off
/// nothing". Old rows get `NULL`, and `Order.discountRule` reads that as
/// `BillDiscount.none`.
///
/// SQLite allows `ADD COLUMN` with a non-null default without rewriting the table, which is
/// why this migration is instant on a terminal with a year of bills on it.
class M009BillTaxAndDiscount implements Migration {
  const M009BillTaxAndDiscount();

  @override
  int get version => 9;

  @override
  String get description => 'GST rate and discount rule on a settled bill';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    // The combined GST rate this bill was charged at, in basis points where 10000 is 100%.
    // Zero for every bill settled before GST could be configured, which is what those bills
    // charged.
    '''
    ALTER TABLE ${SqliteTables.orders}
      ADD COLUMN taxRateBasisPoints INTEGER NOT NULL DEFAULT 0
    ''',
    // Which discount rule was applied: a `BillDiscountType` name, or NULL for none.
    // Nullable rather than defaulted, so "no rule recorded" stays distinguishable from "a
    // rule that came to nothing".
    '''
    ALTER TABLE ${SqliteTables.orders}
      ADD COLUMN discountType TEXT
    ''',
    // The rule's magnitude in hundredths: basis points for a percentage, paise for a flat
    // amount. Meaningless without discountType, which is why they are read together.
    '''
    ALTER TABLE ${SqliteTables.orders}
      ADD COLUMN discountValue INTEGER NOT NULL DEFAULT 0
    ''',
  ];
}
