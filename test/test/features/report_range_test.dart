import 'package:brisko_billing/features/reports/domain/models/date_range.dart';
import 'package:brisko_billing/features/reports/domain/models/report_period.dart';
import 'package:flutter_test/flutter_test.dart';

/// The date filtering behind every report.
///
/// ## Why this is tested on its own
///
/// A sales figure is only as trustworthy as the boundary it was measured to. If "today"
/// drifts by an hour, a bill taken at 11pm lands in the wrong day's takings and two
/// reports that should agree do not. So the boundary is a value type with no clock in it,
/// and it is checked here without a database.
///
/// ## Why every instant is constructed rather than taken from now
///
/// These tests pass in any timezone and at any hour, because "now" is supplied. That is
/// the whole reason [ReportPeriod.resolve] takes an instant instead of calling
/// `DateTime.now()`: a test that waited for the right time of day to be correct is not a
/// test.
void main() {
  group('DateRange', () {
    test('a single day runs from local midnight to the next', () {
      final DateRange range = DateRange.day(DateTime(2026, 9, 13, 14, 35, 12));

      expect(range.firstDay, DateTime(2026, 9, 13));
      expect(range.lastDay, DateTime(2026, 9, 13));
      expect(range.from, DateTime(2026, 9, 13).toUtc());
      expect(range.to, DateTime(2026, 9, 14).toUtc());
      expect(range.isSingleDay, isTrue);
      expect(range.dayCount, 1);
    });

    test(
      'the boundary is half-open, so no bill falls into two days or neither',
      () {
        final DateRange range = DateRange.day(DateTime(2026, 9, 13, 9));

        // First instant of the day is in.
        expect(range.contains(DateTime(2026, 9, 13)), isTrue);
        // Last representable instant of the day is in.
        expect(range.contains(DateTime(2026, 9, 13, 23, 59, 59, 999)), isTrue);
        // Midnight belongs to the next day, not this one.
        expect(range.contains(DateTime(2026, 9, 14)), isFalse);
        // And the instant before the day started is out.
        expect(range.contains(DateTime(2026, 9, 12, 23, 59, 59, 999)), isFalse);
      },
    );

    test('a range spanning several days includes all of the last one', () {
      final DateRange range = DateRange.spanning(
        firstInstant: DateTime(2026, 9, 10, 8),
        lastInstant: DateTime(2026, 9, 12, 8),
      );

      expect(range.firstDay, DateTime(2026, 9, 10));
      expect(range.lastDay, DateTime(2026, 9, 12));
      expect(range.to, DateTime(2026, 9, 13).toUtc());
      expect(range.dayCount, 3);
      expect(range.isSingleDay, isFalse);
      expect(range.contains(DateTime(2026, 9, 12, 22, 30)), isTrue);
    });

    test('dates handed over the wrong way round produce the range meant', () {
      final DateRange reversed = DateRange.spanning(
        firstInstant: DateTime(2026, 9, 12),
        lastInstant: DateTime(2026, 9, 10),
      );

      expect(reversed.firstDay, DateTime(2026, 9, 10));
      expect(reversed.lastDay, DateTime(2026, 9, 12));
      expect(reversed.dayCount, 3);
    });

    test(
      'a range ending on a day includes that day and the ones before it',
      () {
        final DateRange range = DateRange.endingOn(
          DateTime(2026, 9, 13, 16),
          days: 7,
        );

        expect(range.firstDay, DateTime(2026, 9, 7));
        expect(range.lastDay, DateTime(2026, 9, 13));
        expect(range.dayCount, 7);
      },
    );

    test('a range crossing a month boundary counts its days correctly', () {
      final DateRange range = DateRange.endingOn(
        DateTime(2026, 3, 2, 10),
        days: 7,
      );

      expect(range.firstDay, DateTime(2026, 2, 24));
      expect(range.lastDay, DateTime(2026, 3, 2));
      expect(range.dayCount, 7);
    });

    test('a range of no days is refused rather than silently emptied', () {
      expect(
        () => DateRange.endingOn(DateTime(2026, 9, 13), days: 0),
        throwsArgumentError,
      );
    });

    test('two ranges over the same days are equal', () {
      expect(
        DateRange.day(DateTime(2026, 9, 13, 1)),
        DateRange.day(DateTime(2026, 9, 13, 23)),
      );
      expect(
        DateRange.day(DateTime(2026, 9, 13)),
        isNot(DateRange.day(DateTime(2026, 9, 14))),
      );
    });

    test(
      'a UTC instant late in the day is placed in the local day it belongs to',
      () {
        // The range is built from whatever local day contains the instant, so this holds
        // in every timezone rather than only in one.
        final DateTime instant = DateTime.utc(2026, 9, 13, 21, 30);
        final DateRange range = DateRange.day(instant);

        expect(range.contains(instant), isTrue);
        // The day starts at local midnight whatever the offset happens to be.
        expect(range.firstDay.isUtc, isFalse);
        expect(range.firstDay.hour, 0);
        expect(range.firstDay.minute, 0);
        expect(range.firstDay.second, 0);
        expect(range.dayCount, 1);
      },
    );
  });

  group('ReportPeriod', () {
    /// A fixed instant to resolve against. Local, because a report is about the outlet's
    /// day.
    final DateTime now = DateTime(2026, 9, 13, 15, 20);

    test('today is the local day of the clock', () {
      expect(ReportPeriod.today.resolve(now), DateRange.day(now));
      expect(ReportPeriod.today.resolve(now)!.dayCount, 1);
    });

    test('yesterday is the day before, and only that day', () {
      final DateRange range = ReportPeriod.yesterday.resolve(now)!;

      expect(range.firstDay, DateTime(2026, 9, 12));
      expect(range.lastDay, DateTime(2026, 9, 12));
      expect(range.dayCount, 1);
      expect(range.contains(DateTime(2026, 9, 13, 0, 0, 0, 1)), isFalse);
    });

    test('yesterday crosses a month boundary', () {
      final DateRange range = ReportPeriod.yesterday.resolve(
        DateTime(2026, 3, 1, 9),
      )!;

      expect(range.firstDay, DateTime(2026, 2, 28));
      expect(range.lastDay, DateTime(2026, 2, 28));
    });

    test('last 7 days ends today and starts six days earlier', () {
      final DateRange range = ReportPeriod.last7Days.resolve(now)!;

      expect(range.firstDay, DateTime(2026, 9, 7));
      expect(range.lastDay, DateTime(2026, 9, 13));
      expect(range.dayCount, 7);
      // Today is inside it, which is what makes it "this week so far".
      expect(range.contains(now), isTrue);
      // The eighth day back is not.
      expect(range.contains(DateTime(2026, 9, 6, 23, 59)), isFalse);
    });

    test('a custom period cannot be resolved from a clock', () {
      // Deliberately null rather than a guess. A range nobody chose must not be shown
      // under a "Custom" heading.
      expect(ReportPeriod.custom.resolve(now), isNull);
      expect(ReportPeriod.custom.isCustom, isTrue);
    });

    test('every period is labelled', () {
      for (final ReportPeriod period in ReportPeriod.values) {
        expect(period.label, isNotEmpty);
      }
      expect(ReportPeriod.values, hasLength(4));
    });
  });
}
