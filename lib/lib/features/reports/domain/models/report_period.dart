import 'date_range.dart';

/// The date filters offered on the Reports screen.
///
/// Four, because these are the four questions actually asked at a counter: how did
/// today go, how did yesterday go, how is the week going, and what happened between
/// two dates somebody has written down.
///
/// [resolve] is a pure function of the instant handed to it. Nothing in this file
/// reads a clock, which is what lets a test pin "today" and get the same range every
/// run.
enum ReportPeriod {
  today,

  yesterday,

  /// This day and the six before it.
  last7Days,

  /// Two dates chosen by the operator. Has no range of its own; see [resolve].
  custom;

  String get label => switch (this) {
    ReportPeriod.today => 'Today',
    ReportPeriod.yesterday => 'Yesterday',
    ReportPeriod.last7Days => 'Last 7 days',
    ReportPeriod.custom => 'Custom',
  };

  /// True when the operator has to supply the dates.
  bool get isCustom => this == ReportPeriod.custom;

  /// The local days this period covers, relative to [now].
  ///
  /// Returns `null` for [custom], which cannot be resolved from a clock: the whole
  /// point of it is that the dates come from the operator. A `null` is returned rather
  /// than a guessed-at range so a caller cannot accidentally show a week's takings
  /// under a "Custom" label.
  DateRange? resolve(DateTime now) => switch (this) {
    ReportPeriod.today => DateRange.day(now),
    ReportPeriod.yesterday => DateRange.endingOn(
      // A day back through the calendar, not through a 24-hour duration, so a
      // daylight-saving change does not land this on the wrong date.
      _localDaysBefore(now, 1),
      days: 1,
    ),
    ReportPeriod.last7Days => DateRange.endingOn(now, days: 7),
    ReportPeriod.custom => null,
  };

  /// Local noon [days] calendar days before [now].
  ///
  /// Noon rather than midnight so that the value is unambiguously inside the intended
  /// day even where a daylight-saving change moves midnight itself. Only the date is
  /// read from it.
  static DateTime _localDaysBefore(DateTime now, int days) {
    final DateTime local = now.toLocal();
    return DateTime(local.year, local.month, local.day - days, 12);
  }
}
