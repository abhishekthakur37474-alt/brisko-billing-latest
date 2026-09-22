import 'package:flutter/material.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/item_sales_row.dart';
import 'report_notices.dart';

/// What sold in the selected dates, best earner first.
///
/// ## Where the names come from
///
/// The name and size stored on each bill line at the moment of sale, aggregated by the
/// database. Nothing here consults the menu, which is why a dish renamed last week still
/// appears in last month's report under the name it was sold as, and a product deleted
/// from the menu altogether still appears in the months it sold in.
///
/// ## What the amount is
///
/// The sum of the stored line totals, which includes what any customisation added to the
/// line, because that is what the customer paid for it.
class ItemSalesView extends StatelessWidget {
  const ItemSalesView({required this.rows, super.key});

  final List<ItemSalesRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const ReportEmptyView(
        icon: Icons.local_pizza_outlined,
        title: 'Nothing sold in these dates',
        message:
            'This report is built from the lines on settled bills. It fills in '
            'as bills are taken.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      // One header above the rows.
      itemCount: rows.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return const _ItemHeader();
        }
        return _ItemRow(row: rows[index - 1]);
      },
    );
  }
}

class _ItemHeader extends StatelessWidget {
  const _ItemHeader();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Item', style: style)),
          SizedBox(
            width: 72,
            child: Text('Qty', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 112,
            child: Text('Sales', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.row});

  final ItemSalesRow row;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              // The name and size as they were when sold.
              row.displayName,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              '${row.quantitySold}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          SizedBox(
            width: 112,
            child: Text(
              row.salesAmount.formatted,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
