import 'package:flutter/material.dart';

import '../../../printing/domain/print_timestamp.dart';
import '../../domain/models/date_range.dart';
import '../../domain/models/report_period.dart';

/// The date filter: four choices and a plain statement of which days are on screen.
///
/// The dates are spelled out under the chips rather than left implied by the chip that is
/// selected. "Last 7 days" is not a date, and anyone copying a figure off this screen onto
/// paper needs to be able to write down what it covers.
///
/// Contains no business rule and no SQL. Choosing a period is reported upwards; resolving
/// it to actual days is `ReportPeriod`'s job, against the controller's clock.
class ReportFilterBar extends StatelessWidget {
  const ReportFilterBar({
    required this.period,
    required this.range,
    required this.onSelectPeriod,
    required this.onPickCustomRange,
    this.isLoading = false,
    super.key,
  });

  final ReportPeriod period;

  /// The days currently reported on.
  final DateRange range;

  final ValueChanged<ReportPeriod> onSelectPeriod;

  /// Asked to open a date picker. Separate from [onSelectPeriod] because "Custom" has no
  /// dates until the operator supplies them.
  final VoidCallback onPickCustomRange;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (final ReportPeriod option in ReportPeriod.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(option.label),
                            selected: option == period,
                            onSelected: (bool _) => option.isCustom
                                ? onPickCustomRange()
                                : onSelectPeriod(option),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // A word rather than a spinner, for the same reason the loading body has
              // none: the read is over in milliseconds, and an animation that never
              // stops is one nothing can wait for.
              if (isLoading)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'Reading…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _rangeLabel(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// The days on screen, in words.
  ///
  /// Dates are rendered by [PrintTimestamp] so a range on screen reads the same way as a
  /// date on a receipt, in day-month-year order.
  String _rangeLabel() {
    if (range.isSingleDay) {
      return PrintTimestamp.date(range.firstDay);
    }
    return '${PrintTimestamp.date(range.firstDay)} to '
        '${PrintTimestamp.date(range.lastDay)} '
        '(${range.dayCount} days)';
  }
}
