import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../../../core/money/money_display.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../domain/models/payment_mix.dart';
import '../../domain/models/sales_summary.dart';
import 'report_notices.dart';

/// What the selected dates took.
///
/// Reads a [SalesSummary] and a [PaymentMix] and renders them. Every figure was summed by
/// the database from the amounts written when each bill was settled; nothing on this
/// screen is recalculated and nothing is looked up in the menu.
///
/// Cancelled bills are absent from all of it, and a bill that was never settled has no row
/// to be absent from. The caption under the gross figure says so, because a sales total is
/// quoted to people who are entitled to know what it excludes.
class SalesSummaryView extends StatelessWidget {
  const SalesSummaryView({
    required this.summary,
    required this.paymentMix,
    super.key,
  });

  final SalesSummary summary;

  final PaymentMix paymentMix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        _FigureGrid(
          children: <Widget>[
            ReportFigureCard(
              label: 'Sales',
              value: summary.grossSales.formatted,
              caption: 'Settled bills only. Cancelled bills excluded.',
            ),
            ReportFigureCard(
              label: 'Bills',
              value: '${summary.billCount}',
              caption: summary.billCount == 1 ? 'One settled bill' : null,
            ),
            ReportFigureCard(
              label: 'Average bill',
              value: summary.averageBillValue.formatted,
              caption: 'Sales divided by bills',
            ),
            ReportFigureCard(
              label: 'Items sold',
              value: '${summary.itemCount}',
              caption: 'Units across all bills',
            ),
            // Only shown once money has actually gone back. A permanent pair of zero cards
            // would put two figures on every report that almost always say nothing, and the
            // rows inside the breakdown below already account for the case.
            if (summary.hasRefunds) ...<Widget>[
              ReportFigureCard(
                label: 'Refunds',
                value: summary.refundTotal.formatted,
                caption: 'Handed back on these bills',
              ),
              ReportFigureCard(
                label: 'Net sales',
                value: summary.netSales.formatted,
                caption: 'Sales less refunds',
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        Text('How the total is made up', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _AmountRow(label: 'Sales subtotal', amount: summary.subtotal),
                if (summary.hasDiscounts)
                  _AmountRow(
                    label: 'Discounts',
                    amount: -summary.discountTotal,
                  ),
                // What the GST was charged on, stated only when a discount moved it away
                // from the subtotal above. Otherwise it is the same figure twice.
                if (summary.hasDiscounts && summary.hasTax)
                  _AmountRow(
                    label: 'Taxable sales',
                    amount: summary.taxableSales,
                  ),
                // One GST figure in the block, because the block's rows have to add up to
                // the gross beneath them and a CGST row beside an SGST row beside a GST row
                // would appear to be counted three times. The halves are stated below as a
                // caption instead, which is where they belong: they are a breakdown of this
                // figure, not further additions to it.
                if (summary.hasTax) ...<Widget>[
                  _AmountRow(label: 'GST', amount: summary.taxTotal),
                ],
                const Divider(height: 20),
                _AmountRow(
                  label: 'Sales',
                  amount: summary.grossSales,
                  emphasise: true,
                ),
                // The GST split, as a note rather than as two more rows. Allocated from the
                // figure above so the two halves always come to exactly it.
                if (summary.hasTax)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      'GST above is CGST ${summary.cgstTotal.formatted} and '
                      'SGST ${summary.sgstTotal.formatted}. Each bill was taxed '
                      'at the rate in force when it was settled.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                // The sale and its reversal are two facts, so they are two lines. The bill
                // stays counted at what it was rung up for and the refund is subtracted
                // below it, which is what keeps the gross figure reconcilable against the
                // day's receipts.
                if (summary.hasRefunds) ...<Widget>[
                  _AmountRow(label: 'Refunds', amount: -summary.refundTotal),
                  const Divider(height: 20),
                  _AmountRow(
                    label: 'Net sales',
                    amount: summary.netSales,
                    emphasise: true,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Collected by', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // All four methods, every time. A day with no card takings shows a card
                // row at zero rather than dropping it, so nobody has to wonder whether
                // the report forgot about card.
                for (final PaymentMethod method in PaymentMix.methods)
                  _AmountRow(
                    label: method.label,
                    amount: paymentMix.amountFor(method),
                  ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Collected',
                  amount: paymentMix.total,
                  emphasise: true,
                ),
                // What the drawer paid back out, by the method it came in on, and what it is
                // left holding. Only present once a reversal exists, so an ordinary day's
                // breakdown reads exactly as it did before refunds were possible.
                if (paymentMix.hasRefunds) ...<Widget>[
                  _AmountRow(
                    label: 'Refunded',
                    amount: -paymentMix.refundTotal,
                  ),
                  const Divider(height: 20),
                  _AmountRow(
                    label: 'Net collected',
                    amount: paymentMix.netTotal,
                    emphasise: true,
                  ),
                ],
                // Said out loud rather than smoothed over. Settled tenders less settled
                // refunds should add up to the settled bills less those same refunds; where
                // they do not, that is a fact about the records and whoever is reconciling
                // the till has to know it before they quote either figure.
                //
                // Compared net against net rather than gross against gross, so a refund —
                // which reduces both sides equally — never raises this warning on its own.
                if (paymentMix.netTotal != summary.netSales) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'Settled tenders come to ${paymentMix.netTotal.formatted}, '
                    'which does not match the '
                    '${summary.netSales.formatted} billed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
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

/// The figure cards, two across on a counter tablet and one on a phone.
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
    required this.amount,
    this.emphasise = false,
  });

  final String label;

  final Money amount;

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
          Text(amount.formatted, style: style),
        ],
      ),
    );
  }
}
