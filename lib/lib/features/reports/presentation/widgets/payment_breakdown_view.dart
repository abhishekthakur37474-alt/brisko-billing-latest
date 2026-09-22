import 'package:flutter/material.dart';

import '../../../../core/money/money_display.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../domain/models/payment_mix.dart';
import 'report_notices.dart';

/// How the selected dates' takings were tendered.
///
/// ## What is on screen
///
/// One row for each of the four methods the outlet accepts — cash, UPI, card and anything
/// else — with the number of tenders and the total. All four appear whether or not anything
/// was taken on them, because a missing row reads as a report that forgot a method rather
/// than as a zero.
///
/// There is no wallet or loyalty row. Those are not tenders this outlet takes, and a
/// heading no payment can land in is a heading somebody will eventually ask about.
///
/// ## What counts
///
/// Confirmed tenders against settled bills. A UPI attempt still awaiting confirmation is
/// not money in, and a tender against a cancelled bill is not takings.
class PaymentBreakdownView extends StatelessWidget {
  const PaymentBreakdownView({required this.paymentMix, super.key});

  final PaymentMix paymentMix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (paymentMix.isEmpty) {
      return const ReportEmptyView(
        icon: Icons.payments_outlined,
        title: 'Nothing collected in these dates',
        message: 'This report is built from the confirmed payments on settled bills.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const _MethodHeader(),
                const Divider(height: 16),
                for (final PaymentMethod method in PaymentMix.methods)
                  _MethodRow(
                    label: method.label,
                    tenders: paymentMix.countFor(method),
                    amount: paymentMix.amountFor(method).formatted,
                  ),
                const Divider(height: 16),
                _MethodRow(
                  label: 'Collected',
                  tenders: paymentMix.tenderCount,
                  amount: paymentMix.total.formatted,
                  emphasise: true,
                ),
              ],
            ),
          ),
        ),
        // A second card rather than more rows in the first, because these are movements in
        // the opposite direction and interleaving them would let a reader add a column that
        // means nothing. Absent entirely until money has actually gone back.
        if (paymentMix.hasRefunds) ...<Widget>[
          const SizedBox(height: 16),
          Text('Refunded', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _MethodHeader(refunds: true),
                  const Divider(height: 16),
                  for (final PaymentMethod method in PaymentMix.methods)
                    _MethodRow(
                      label: method.label,
                      tenders: paymentMix.refundCountFor(method),
                      amount: paymentMix.refundedFor(method).formatted,
                    ),
                  const Divider(height: 16),
                  _MethodRow(
                    label: 'Handed back',
                    tenders: paymentMix.refundCount,
                    amount: paymentMix.refundTotal.formatted,
                    emphasise: true,
                  ),
                  const Divider(height: 16),
                  // What the drawer is left holding, which is the figure that reconciles
                  // against net sales on the summary.
                  _MethodRow(
                    label: 'Net collected',
                    tenders: paymentMix.tenderCount - paymentMix.refundCount,
                    amount: paymentMix.netTotal.formatted,
                    emphasise: true,
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Where a bill was settled with more than one tender, each tender is '
          'counted under its own method. A refund is counted under the method '
          'the money went back by.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MethodHeader extends StatelessWidget {
  const _MethodHeader({this.refunds = false});

  /// True when the card below counts reversals rather than tenders, so the count column is
  /// labelled for what it actually counts.
  final bool refunds;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Row(
      children: <Widget>[
        Expanded(child: Text('Method', style: style)),
        SizedBox(
          width: 80,
          child: Text(
            refunds ? 'Refunds' : 'Tenders',
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
        SizedBox(
          width: 112,
          child: Text('Amount', textAlign: TextAlign.right, style: style),
        ),
      ],
    );
  }
}

class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.label,
    required this.tenders,
    required this.amount,
    this.emphasise = false,
  });

  final String label;

  final int tenders;

  /// Already formatted, so this widget never sees an amount it could alter.
  final String amount;

  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = emphasise
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          SizedBox(
            width: 80,
            child: Text('$tenders', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 112,
            child: Text(amount, textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}
