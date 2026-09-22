/// A span of whole local calendar days, as a half-open instant range.
///
/// ## Why the days are local and the instants are UTC
///
/// Everything in the database is stored as UTC milliseconds, but "today's sales" is a
/// question about the outlet's day, not about Greenwich. A bill taken at 11pm on the
/// 12th is part of the 12th's takings even though it is already the 13th in UTC. So a
/// range is defined by its first and last *local* calendar day, and the instants that
/// bound it are derived from those days.
///
/// [firstDay] and [lastDay] are local `DateTime`s at midnight. [from] and [to] are the
/// UTC instants a query compares `createdAt` against.
///
/// ## Why the instant range is half-open
///
/// [from] is inclusive and [to] is exclusive, which is the convention
/// `OrderRepository.loadOrders` already uses. It means a day can be expressed without
/// naming the last millisecond of it, so there is no gap at 23:59:59.999 and no bill
/// can fall into two adjacent ranges or neither.
///
/// ## Determinism
///
/// Nothing here reads a clock. A range is built from instants the caller supplies, so
/// the caller — a controller with an injected clock, or a test — decides what "now"
/// means. That is what makes a report's boundaries reproducible.
class DateRange {
  DateRange._(this.firstDay, this.lastDay);

  /// The single local day that contains [instant].
  factory DateRange.day(DateTime instant) =>
      DateRange.spanning(firstInstant: instant, lastInstant: instant);

  /// Every local day from the day containing [firstInstant] to the day containing
  /// [lastInstant], both included.
  ///
  /// The two are swapped if they arrive the wrong way round, so a date picker that
  /// hands back an end before a start produces the range the operator meant rather
  /// than an empty one.
  factory DateRange.spanning({
    required DateTime firstInstant,
    required DateTime lastInstant,
  }) {
    final DateTime first = _startOfLocalDay(firstInstant);
    final DateTime last = _startOfLocalDay(lastInstant);
    return first.isAfter(last)
        ? DateRange._(last, first)
        : DateRange._(first, last);
  }

  /// The [days] local days ending with the day that contains [lastInstant].
  ///
  /// Inclusive of that last day, so `days: 7` on a Sunday runs Monday to Sunday. That
  /// is what "last 7 days" means at a counter: this week so far, not the week before
  /// it plus today.
  factory DateRange.endingOn(DateTime lastInstant, {required int days}) {
    if (days < 1) {
      throw ArgumentError.value(days, 'days', 'Must be at least one day');
    }
    final DateTime last = _startOfLocalDay(lastInstant);
    // Day arithmetic through the constructor rather than `subtract(Duration(days:))`.
    // A duration is a fixed number of hours, so across a daylight-saving change it
    // would land at 23:00 the previous day and quietly widen the range.
    final DateTime first = DateTime(
      last.year,
      last.month,
      last.day - (days - 1),
    );
    return DateRange._(first, last);
  }

  /// Local midnight of the first day included. Inclusive.
  final DateTime firstDay;

  /// Local midnight of the last day included. Inclusive — the day itself is counted
  /// in full, which [to] is what expresses.
  final DateTime lastDay;

  /// Earliest instant in the range, in UTC. Inclusive.
  DateTime get from => firstDay.toUtc();

  /// Instant the range stops at, in UTC. Exclusive.
  ///
  /// Local midnight at the start of the day after [lastDay]. Built through the
  /// constructor so a month or year boundary rolls over correctly and a
  /// daylight-saving change is respected.
  DateTime get to =>
      DateTime(lastDay.year, lastDay.month, lastDay.day + 1).toUtc();

  /// True when the range is one calendar day.
  bool get isSingleDay =>
      firstDay.year == lastDay.year &&
      firstDay.month == lastDay.month &&
      firstDay.day == lastDay.day;

  /// Number of local days covered, counting both ends.
  ///
  /// Measured between the two dates as UTC midnights, so the count is a plain
  /// difference in days and a daylight-saving change inside the range cannot make it
  /// come out at 6.96 days and truncate to 6.
  int get dayCount =>
      DateTime.utc(lastDay.year, lastDay.month, lastDay.day)
          .difference(DateTime.utc(firstDay.year, firstDay.month, firstDay.day))
          .inDays +
      1;

  /// True when [instant] falls inside the range.
  bool contains(DateTime instant) {
    final DateTime at = instant.toUtc();
    return !at.isBefore(from) && at.isBefore(to);
  }

  /// Local midnight of the day containing [instant].
  ///
  /// Constructed field by field rather than by subtracting a duration, so it is
  /// genuinely the start of the local day whatever the offset happens to be.
  static DateTime _startOfLocalDay(DateTime instant) {
    final DateTime local = instant.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay;

  @override
  int get hashCode => Object.hash(firstDay, lastDay);

  @override
  String toString() => 'DateRange($firstDay .. $lastDay)';
}
