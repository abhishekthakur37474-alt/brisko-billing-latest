import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../app/routes/app_routes.dart';
import '../../../../core/money/money_display.dart';
import '../../../inventory/domain/models/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../orders/presentation/widgets/bill_detail_view.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../../reports/domain/models/item_sales_row.dart';
import '../../../reports/domain/models/payment_mix.dart';
import '../../../reports/domain/models/report_period.dart';
import '../../../reports/domain/models/sales_bill.dart';
import '../../../reports/domain/models/sales_summary.dart';
import '../../../reports/domain/repositories/sales_report_repository.dart';
import '../../../reports/presentation/widgets/report_notices.dart';
import '../controllers/dashboard_controller.dart';

/// The "Today" dashboard: what the outlet has taken so far, and what needs an eye kept on it.
///
/// ## Where the figures come from
///
/// The same aggregation the Reports screen uses. Discount, GST, refunds and net sales are
/// `SalesSummary`'s figures, unaltered, so this screen and the reports agree by construction
/// — the GST shown here is one figure, never CGST and SGST added together. Nothing is
/// recalculated and no menu table is read.
///
/// ## What it deliberately is not
///
/// An analytics screen. There are no charts, no trends and no forecasts: the outlet reads
/// this standing at a till, and a labelled number is faster to read than anything plotted.
/// The full item report, the payment breakdown and the whole bill list live one tap away in
/// Reports and in the order history.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DashboardController>(
      create: (BuildContext context) {
        final DashboardController controller = DashboardController(
          reportRepository: context.read<SalesReportRepository>(),
          inventoryRepository: context.read<InventoryRepository>(),
        );
        // Not awaited: the first frame shows the loading state while the reads run.
        unawaited(controller.load());
        return controller;
      },
      child: const _DashboardBody(),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody();

  @override
  Widget build(BuildContext context) {
    final DashboardController controller = context.watch<DashboardController>();

    return Column(
      children: <Widget>[
        _PeriodBar(controller: controller),
        Expanded(child: _Content(controller: controller)),
      ],
    );
  }
}

/// The three periods a dashboard offers, and the days on screen spelled out.
class _PeriodBar extends StatelessWidget {
  const _PeriodBar({required this.controller});

  final DashboardController controller;

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
                child: Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final ReportPeriod option
                        in DashboardController.periods)
                      ChoiceChip(
                        label: Text(option.label),
                        selected: option == controller.period,
                        onSelected: (bool _) =>
                            unawaited(controller.selectPeriod(option)),
                      ),
                  ],
                ),
              ),
              if (controller.isLoading)
                Text(
                  'Reading…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

  String _rangeLabel() {
    if (controller.range.isSingleDay) {
      return PrintTimestamp.date(controller.range.firstDay);
    }
    return '${PrintTimestamp.date(controller.range.firstDay)} to '
        '${PrintTimestamp.date(controller.range.lastDay)} '
        '(${controller.range.dayCount} days)';
  }
}

/// Order matters, as it does on the reports: a fault is reported before anything else,
/// because a figure shown beside an error is a figure somebody will quote.
class _Content extends StatelessWidget {
  const _Content({required this.controller});

  final DashboardController controller;

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

    final SalesSummary summary = controller.summary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        if (controller.isEmpty)
          _NoSalesYet(range: controller.range.isSingleDay)
        else ...<Widget>[
          _SummaryFigures(summary: summary),
          const SizedBox(height: 24),
          _PaymentMixCard(paymentMix: controller.paymentMix),
          const SizedBox(height: 24),
          _TopItemsCard(items: controller.topItems),
        ],
        if (controller.hasLowStock) ...<Widget>[
          const SizedBox(height: 24),
          _LowStockCard(items: controller.lowStock),
        ],
        const SizedBox(height: 24),
        _RecentOrdersSection(controller: controller),
      ],
    );
  }
}

/// The honest "nothing sold yet" panel, with no example figures.
class _NoSalesYet extends StatelessWidget {
  const _NoSalesYet({required this.range});

  final bool range;

  @override
  Widget build(BuildContext context) {
    return ReportEmptyView(
      icon: Icons.point_of_sale_outlined,
      title: range ? 'No sales yet today' : 'No sales in these dates',
      message:
          'Figures appear here as bills are settled at the counter. '
          'Cancelled bills are never counted as sales.',
    );
  }
}

/// The headline figures. Discount, GST, refunds and net are only shown once they are more
/// than nothing, so an ordinary day is not crowded with zeroes.
class _SummaryFigures extends StatelessWidget {
  const _SummaryFigures({required this.summary});

  final SalesSummary summary;

  @override
  Widget build(BuildContext context) {
    return _FigureGrid(
      children: <Widget>[
        ReportFigureCard(
          label: 'Gross sales',
          value: summary.grossSales.formatted,
          caption: 'Settled bills only',
        ),
        ReportFigureCard(
          label: 'Orders settled',
          value: '${summary.billCount}',
          caption: summary.billCount == 1 ? 'One settled bill' : null,
        ),
        ReportFigureCard(
          label: 'Average order',
          value: summary.averageBillValue.formatted,
          caption: 'Gross divided by orders',
        ),
        ReportFigureCard(label: 'Items sold', value: '${summary.itemCount}'),
        if (summary.hasDiscounts)
          ReportFigureCard(
            label: 'Discounts',
            value: summary.discountTotal.formatted,
            caption: 'Given on these bills',
          ),
        if (summary.hasTax)
          ReportFigureCard(
            label: 'GST',
            value: summary.taxTotal.formatted,
            caption:
                'CGST ${summary.cgstTotal.formatted} + SGST '
                '${summary.sgstTotal.formatted}',
          ),
        if (summary.hasRefunds) ...<Widget>[
          ReportFigureCard(
            label: 'Refunds',
            value: summary.refundTotal.formatted,
            caption: 'Handed back on these bills',
          ),
          ReportFigureCard(
            label: 'Net sales',
            value: summary.netSales.formatted,
            caption: 'Gross less refunds',
          ),
        ],
      ],
    );
  }
}

/// How the takings were tendered, all four methods every time.
class _PaymentMixCard extends StatelessWidget {
  const _PaymentMixCard({required this.paymentMix});

  final PaymentMix paymentMix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Payment mix', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final PaymentMethod method in PaymentMix.methods)
                  _AmountRow(
                    label: method.label,
                    value: paymentMix.amountFor(method).formatted,
                  ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Collected',
                  value: paymentMix.total.formatted,
                  emphasise: true,
                ),
                if (paymentMix.hasRefunds) ...<Widget>[
                  _AmountRow(
                    label: 'Refunded',
                    value: '-${paymentMix.refundTotal.formatted}',
                  ),
                  _AmountRow(
                    label: 'Net collected',
                    value: paymentMix.netTotal.formatted,
                    emphasise: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The best sellers, most valuable first. A glance; the full report is in Reports.
class _TopItemsCard extends StatelessWidget {
  const _TopItemsCard({required this.items});

  final List<ItemSalesRow> items;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Top selling items', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: items.isEmpty
                ? Text(
                    'Nothing sold in this period yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final ItemSalesRow row in items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  row.displayName,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              SizedBox(
                                width: 56,
                                child: Text(
                                  '${row.quantitySold}',
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              SizedBox(
                                width: 104,
                                child: Text(
                                  row.salesAmount.formatted,
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Stock at or below its reorder threshold. Only present when there is something to warn
/// about, so a healthy shelf shows nothing rather than an empty card.
class _LowStockCard extends StatelessWidget {
  const _LowStockCard({required this.items});

  final List<InventoryItem> items;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              Icons.warning_amber_outlined,
              size: 18,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 6),
            Text('Low stock', style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final InventoryItem item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            item.name,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Text(
                          '${item.currentQuantityWithUnit} left '
                          '(min ${item.minimumQuantityWithUnit})',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The most recent settled bills, and the way through to the full order history.
class _RecentOrdersSection extends StatelessWidget {
  const _RecentOrdersSection({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<SalesBill> bills = controller.recentBills;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Recent orders', style: theme.textTheme.titleSmall),
            ),
            TextButton.icon(
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.orderHistory),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('Order history'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (bills.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No orders settled in this period yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final SalesBill bill in bills) _RecentOrderTile(bill: bill),
      ],
    );
  }
}

/// One recent bill. Tapping it opens the same stored-document view the reports and the
/// customer history use.
class _RecentOrderTile extends StatelessWidget {
  const _RecentOrderTile({required this.bill});

  final SalesBill bill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => BillDetailView.show(context, orderId: bill.orderId),
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Bill ${bill.orderNumber}',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(bill.total.formatted, style: theme.textTheme.titleSmall),
          ],
        ),
        subtitle: Text(
          <String>[
            PrintTimestamp.time(bill.placedAt),
            bill.orderType.label,
            if (bill.paymentMethod != null) bill.paymentMethod!.label,
            if (bill.isRefunded) 'Refunded',
          ].join('  ·  '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: bill.isRefunded
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// The figure cards, two across on a counter tablet and four on a wide one, matching the
/// reports layout so the two screens read the same.
class _FigureGrid extends StatelessWidget {
  const _FigureGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 720 ? 4 : 2;
        const double gap = 12;
        final double width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final Widget child in children)
              SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;

  final String value;

  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = emphasise
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
