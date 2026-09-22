import 'package:sqflite/sqflite.dart';

import '../../../core/data/local/sqlite/sqlite_tables.dart';

/// Allocates the human-readable slip number, `K20260911-0001`.
///
/// Mirrors `OrderNumberSequence` deliberately, including taking a
/// [DatabaseExecutor] rather than a `Database`. That is what lets settlement
/// allocate the number against its own open transaction: a settlement that rolls
/// back consumes no slip number, so the kitchen never sees a gap it cannot account
/// for. The unique index on `kot_records.kotNumber` is what ultimately prevents a
/// collision.
class KotNumberSequence {
  const KotNumberSequence._();

  /// Distinguishes a slip number from an order number at a glance, on paper and
  /// when read aloud.
  static const String prefix = 'K';

  static const String separator = '-';

  /// Digits in the daily sequence. Four allows 9999 slips in a day.
  static const int sequenceDigits = 4;

  /// The `yyyyMMdd` part of a number, in local time.
  ///
  /// Local rather than UTC for the same reason order numbers are: a slip raised at
  /// 1am belongs to the day the outlet believes it is.
  static String datePart(DateTime at) {
    return '${at.year.toString().padLeft(4, '0')}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}';
  }

  /// The next unused slip number for the day containing [at], defaulting to now.
  ///
  /// Pass the `Transaction` as [db] to allocate and insert atomically.
  static Future<String> next(DatabaseExecutor db, {DateTime? at}) async {
    final String date = datePart(at ?? DateTime.now());

    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT kotNumber FROM ${SqliteTables.kotRecords} '
      'WHERE kotNumber LIKE ? '
      'ORDER BY kotNumber DESC LIMIT 1',
      <Object?>['$prefix$date$separator%'],
    );

    final String sequence = _sequenceAfter(rows)
        .toString()
        .padLeft(sequenceDigits, '0');
    return '$prefix$date$separator$sequence';
  }

  /// Reads the sequence out of the highest existing number and increments it.
  ///
  /// A number that cannot be read falls back to 1 rather than throwing, so one
  /// malformed historical row cannot stop the outlet raising slips. The unique index
  /// refuses the write if that fallback would collide.
  static int _sequenceAfter(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      return 1;
    }

    final String last = rows.first['kotNumber']! as String;
    final int separatorIndex = last.lastIndexOf(separator);
    if (separatorIndex == -1) {
      return 1;
    }

    final int? issued = int.tryParse(last.substring(separatorIndex + 1));
    return issued == null ? 1 : issued + 1;
  }
}
