import 'package:flutter/material.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/bill_totals.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cart_line.dart';

/// Read-only statement of what is being charged: the lines, then the money.
///
/// Used on every step of checkout and on the settled bill, so the figures the cashier
/// confirms are rendered by the same code that shows them afterwards. Every amount is
/// read from the cart and the totals; nothing is summed here.
class BillSummaryPanel extends StatelessWidget {
  const BillSummaryPanel({
    required this.cart,
    required this.totals,
    this.title = 'Bill',
    this.customerName,
    this.customerPhone,
    super.key,
  });

  /// Fits the longest item name with a size, a quantity and a line total.
  static const double width = 372;

  final Cart cart;

  final BillTotals totals;

  final String title;

  /// Name taken on this bill, if any.
  final String? customerName;

  /// Phone taken on this bill, if any.
  final String? customerPhone;

  bool get _hasName =>
      customerName != null && customerName!.trim().isNotEmpty;

  bool get _hasPhone =>
      customerPhone != null && customerPhone!.trim().isNotEmpty;

  bool get _hasCustomer => _hasName || _hasPhone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title, style: theme.textTheme.titleMedium),
              Text(
                '${cart.lineCount} '
                '${cart.lineCount == 1 ? 'line' : 'lines'} \u00b7 '
                '${cart.itemCount} '
                '${cart.itemCount == 1 ? 'item' : 'items'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_hasCustomer) ...<Widget>[
                const SizedBox(height: 8),
                if (_hasName)
                  Text(
                    customerName!.trim(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (_hasPhone)
                  Text(
                    customerPhone!.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: cart.lineCount,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                _SummaryLine(line: cart.lines[index]),
          ),
        ),
        const Divider(height: 1),
        _TotalsBlock(totals: totals),
      ],
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? optionsSummary = line.optionsSummary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 32,
                child: Text(
                  '${line.quantity}\u00d7',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  line.displayName,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Text(line.lineTotal.formatted, style: theme.textTheme.bodyMedium),
            ],
          ),
          if (optionsSummary != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(
                optionsSummary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TotalsBlock extends StatelessWidget {
  const _TotalsBlock({required this.totals});

  final BillTotals totals;

  /// `CGST 9%`, or plain `CGST` when the rate is unknown or does not halve into a whole
  /// basis point.
  ///
  /// The rate is never stated unless it multiplies out exactly to the figure beside it.
  static String _halfLabel(String tax, BillTotals totals) {
    final String? half = totals.taxRate.isCharged
        ? totals.taxRate.halfLabel
        : null;
    return half == null ? tax : '$tax $half';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AmountRow(
            label: 'Subtotal',
            amount: totals.subtotal.formatted,
            style: theme.textTheme.bodyMedium,
          ),
          // Each row appears only when it says something. The same rule the printed bill
          // follows, so the screen the cashier confirms and the paper the customer keeps
          // show the same lines.
          if (totals.hasDiscount) ...<Widget>[
            const SizedBox(height: 4),
            _AmountRow(
              label: totals.discountRule.isNone
                  ? 'Discount'
                  : 'Discount (${totals.discountRule.label})',
              amount: '-${totals.discount.formatted}',
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (totals.showsTaxableAmount) ...<Widget>[
            const SizedBox(height: 4),
            _AmountRow(
              label: 'Taxable amount',
              amount: totals.taxableAmount.formatted,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (totals.hasTax) ...<Widget>[
            const SizedBox(height: 4),
            _AmountRow(
              label: _halfLabel('CGST', totals),
              amount: totals.cgst.formatted,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            _AmountRow(
              label: _halfLabel('SGST', totals),
              amount: totals.sgst.formatted,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Text('Total', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                totals.total.formatted,
                style: theme.textTheme.headlineSmall,
              ),
            ],
          ),
          if (!totals.hasAdjustments) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              totals.taxRate.isZero
                  ? 'No GST is configured, so this bill is not taxed.'
                  : 'No discount is applied.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.amount,
    required this.style,
  });

  final String label;

  final String amount;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        // The label yields, the amount never does. A label can now be as long as
        // `Discount (₹1,000.00)` or `Taxable amount`, and on a narrow panel the row has to
        // give somewhere — but an amount that got ellipsised or pushed off the edge would be
        // a figure the cashier cannot read on the screen they are confirming.
        Expanded(
          child: Text(
            label,
            style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(amount, style: style),
      ],
    );
  }
}
