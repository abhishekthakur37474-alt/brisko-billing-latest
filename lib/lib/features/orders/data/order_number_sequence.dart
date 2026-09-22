import 'package:sqflite/sqflite.dart';

import '../../../core/data/local/sqlite/sqlite_tables.dart';

/// Allocates the human-readable order number printed on a bill.
///
/// ## Format
///
/// `yyyyMMdd-NNNN`, for example `20260911-0007`. The date is in the number because
/// that is how the counter reads it out and how a day's bills are found again, and the
/// sequence restarts each day so it stays short.
///
/// ## Why counting is safe here
///
/// The next number is derived by taking the highest number already issued for today
/// and adding one. That is only sound while a single terminal issues numbers, which is
/// the current architecture: there is no second till to race with, and the application
/// is single-isolate, so two settlements cannot interleave between the read and the
/// insert.
///
/// Two things keep it safe rather than merely lucky:
///
/// * [next] takes a [DatabaseExecutor], so the caller can pass the `Transaction` it is
///   about to insert into. Read and write then commit together, and a rolled-back
///   settlement consumes no number.
/// * `orders.orderNumber` carries a unique index, and the upsert helper resolves
///   conflicts on `id` only. A duplicate number is therefore *refused* rather than
///   overwriting the bill that already holds it.
///
/// Multi-terminal numbering needs a different design — a per-terminal prefix or a
/// reservation table — and is deliberately not attempted here.
class OrderNumberSequence {
  const OrderNumberSequence._();

  /// Separates the date from the sequence.
  static const String separator = '-';

  /// Digits in the daily sequence. Four allows 9999 bills in a day.
  static const int sequenceDigits = 4;

  /// The `yyyyMMdd` part of a number, in local time.
  ///
  /// Local rather than UTC on purpose: a bill taken at 1am belongs to the day the
  /// outlet believes it is, not to whatever UTC says.
  static String datePart(DateTime at) {
    return '${at.year.toString().padLeft(4, '0')}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}';
  }

  /// The next unused number for the day containing [at], defaulting to now.
  ///
  /// Pass the `Transaction` as [db] to allocate and insert atomically.
  static Future<String> next(DatabaseExecutor db, {DateTime? at}) async {
    final String date = datePart(at ?? DateTime.now());

    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT orderNumber FROM ${SqliteTables.orders} '
      'WHERE orderNumber LIKE ? '
      'ORDER BY orderNumber DESC LIMIT 1',
      <Object?>['$date$separator%'],
    );

    return '$date$separator${_sequenceAfter(rows).toString().padLeft(sequenceDigits, '0')}';
  }

  /// Reads the sequence out of the highest existing number and increments it.
  ///
  /// A number that cannot be read falls back to 1 rather than throwing. The unique
  /// index is what ultimately prevents a collision, and refusing to open the till
  /// because one historical row is malformed would be the worse failure.
  static int _sequenceAfter(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      return 1;
    }

    final String last = rows.first['orderNumber']! as String;
    final int separatorIndex = last.lastIndexOf(separator);
    if (separatorIndex == -1) {
      return 1;
    }

    final int? issued = int.tryParse(last.substring(separatorIndex + 1));
    return issued == null ? 1 : issued + 1;
  }
}
