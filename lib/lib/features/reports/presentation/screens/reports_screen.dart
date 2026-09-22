import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/models/report_period.dart';
import '../../domain/repositories/sales_report_repository.dart';
import '../controllers/sales_report_controller.dart';
import '../report_section.dart';
import '../widgets/item_sales_view.dart';
import '../widgets/payment_breakdown_view.dart';
import '../widgets/report_filter_bar.dart';
import '../widgets/report_notices.dart';
import '../widgets/sales_bills_view.dart';
import '../widgets/sales_summary_view.dart';

/// What the outlet has sold, over dates the operator chooses.
///
/// ## What this screen answers
///
/// Four questions, in the order a shift asks them. What came in today. Which bills made it
/// up. What sold. How it was paid. A date filter sits above all four, so the same four
/// answers are available for yesterday, for the week, or for two dates somebody has been
/// asked about.
///
/// ## Where every figure comes from
///
/// The local SQLite database, and only from bills that were settled. Aggregation happens in
/// SQL; this widget renders what [SalesReportController] holds. There is no network call
/// behind any of it — the reports work with the terminal unplugged, which is the state a
/// power cut leaves it in.
///
/// No menu table is read anywhere behind this screen. Every name, size and amount is a
/// snapshot written when the bill was settled, so repricing a dish, renaming it or removing
/// it changes what the next bill says and cannot change a figure here. Tapping a bill opens
/// the same stored-document view the customer history uses, for the same reason.
///
/// ## What it does not offer
///
/// Reprinting. The terminal has no printer attached yet, and a report offering to reprint a
/// bill would be promising paper the outlet cannot produce.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SalesReportController>(
      create: (BuildContext context) {
        final SalesReportController controller = SalesReportController(
          reportRepository: context.read<SalesReportRepository>(),
        );
        // Deliberately not awaited: the first frame shows the loading state while the
        // reads run.
        unawaited(controller.load());
        return controller;
      },
      child: const _ReportsBody(),
    );
  }
}

class _ReportsBody extends StatelessWidget {
  const _ReportsBody();

  @override
  Widget build(BuildContext context) {
    final SalesReportController controller = context
        .watch<SalesReportController>();

    return DefaultTabController(
      length: ReportSection.values.length,
      child: Column(
        children: <Widget>[
          ReportFilterBar(
            period: controller.period,
            range: controller.range,
            isLoading: controller.isLoading,
            onSelectPeriod: (ReportPeriod period) =>
                unawaited(controller.selectPeriod(period)),
            onPickCustomRange: () => unawaited(_pickRange(context, controller)),
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: <Widget>[
              for (final ReportSection section in ReportSection.values)
                Tab(text: section.label),
            ],
          ),
          Expanded(child: _Body(controller: controller)),
        ],
      ),
    );
  }

  /// Asks for two dates and reports on them.
  ///
  /// The picker is capped at today, because there are no sales in the future and offering
  /// to report on next week invites somebody to conclude the terminal has lost data. Its
  /// lower bound is deliberately generous rather than tied to the first bill: finding that
  /// out would be another query for no gain, and an empty range reports itself honestly.
  Future<void> _pickRange(
    BuildContext context,
    SalesReportController controller,
  ) async {
    final DateTime lastSelectable =
        controller.range.lastDay.isAfter(DateTime.now())
        ? controller.range.lastDay
        : DateTime.now();

    final DateTimeRange? chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(lastSelectable.year - 5),
      lastDate: lastSelectable,
      initialDateRange: DateTimeRange(
        start: controller.range.firstDay,
        end: controller.range.lastDay,
      ),
      helpText: 'Report on these dates',
    );

    if (chosen == null) {
      // Dismissed. The report on screen is left as it was rather than blanked.
      return;
    }

    await controller.selectCustomRange(
      firstDay: chosen.start,
      lastDay: chosen.end,
    );
  }
}

/// The active report, or the state that stands in for it.
///
/// Order matters. A failure is reported before anything else, because a figure shown beside
/// an error is a figure somebody will quote. The empty state comes next, and only then the
/// reports themselves.
class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final SalesReportController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const ReportLoadingView();
    }

    if (controller.hasError) {
      return ReportErrorView(
        message: controller.errorMessage!,
        onRetry: () => unawaited(controller.retry()),
      );
    }

    if (controller.isEmpty) {
      return ReportEmptyView(
        title: controller.range.isSingleDay
            ? 'No sales on this date'
            : 'No sales in these dates',
        message:
            'Nothing has been settled in the dates selected. Figures appear '
            'here as bills are taken, and cancelled bills are never counted '
            'as sales.',
      );
    }

    return TabBarView(
      children: <Widget>[
        for (final ReportSection section in ReportSection.values)
          _sectionView(section),
      ],
    );
  }

  /// Maps a report to the widget that draws it.
  Widget _sectionView(ReportSection section) {
    return switch (section) {
      ReportSection.summary => SalesSummaryView(
        summary: controller.summary,
        paymentMix: controller.paymentMix,
      ),
      ReportSection.bills => SalesBillsView(bills: controller.bills),
      ReportSection.items => ItemSalesView(rows: controller.itemSales),
      ReportSection.payments => PaymentBreakdownView(
        paymentMix: controller.paymentMix,
      ),
    };
  }
}
