import 'package:flutter/material.dart';

import '../../../../core/money/money_display.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/presentation/widgets/bill_detail_view.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../domain/models/sales_bill.dart';
import 'report_notices.dart';

/// The settled bills in the selected dates, newest first.
///
/// ## Where these rows come from
///
/// The `orders` table, through the reports repository. Not the cart: a bill appears here
/// once it has been settled and written, and a half-built bill at the counter is not on
/// this list because it is not yet a sale. Closing the application and reopening it changes
/// nothing about what is shown.
///
/// ## Opening one
///
/// Tapping a row opens [BillDetailView], the same stored-bill view the customer history
/// uses. It reads the persisted snapshots — names, sizes, options, unit prices and totals as
/// charged — so a bill from months ago opens correctly after the dish has been renamed,
/// repriced or taken off the menu.
class SalesBillsView extends StatelessWidget {
  const SalesBillsView({required this.bills, super.key});

  final List<SalesBill> bills;

  @override
  Widget build(BuildContext context) {
    if (bills.isEmpty) {
      return const ReportEmptyView(
        title: 'No settled bills in these dates',
        message:
            'A bill appears here as soon as it is settled at the counter. '
            'Cancelled bills are not listed as sales.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: bills.length,
      itemBuilder: (BuildContext context, int index) =>
          _BillRow(bill: bills[index]),
    );
  }
}

/// One settled bill. Tapping it opens the stored document.
class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill});

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
            Text(
              // The persisted total. Never recomputed from the menu.
              bill.total.formatted,
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              _meta(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(_who(), style: theme.textTheme.bodySmall),
            // The bill keeps its full figure above, because that is what it was rung up
            // for. This line is how the list stops a reversed bill reading as an ordinary
            // sale.
            if (bill.isRefunded) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                'Refunded ${bill.refundedAmount.formatted}  ·  net '
                '${bill.netTotal.formatted}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }

  /// When it was taken, how it was taken, how it was paid, and the slip number.
  ///
  /// The payment method is omitted rather than guessed at where no settled tender is
  /// stored, and the slip number is omitted where no slip was raised. An invented value in
  /// either place would be read as fact.
  String _meta() {
    return <String>[
      // Stored UTC, shown local: a bill taken at 2pm has to read as 2pm.
      PrintTimestamp.stamp(bill.placedAt),
      bill.orderType.label,
      if (bill.paymentMethod != null) bill.paymentMethod!.label,
      if (bill.kotNumber != null) 'KOT ${bill.kotNumber}',
    ].join('  ·  ');
  }

  /// The customer, or that there was not one.
  ///
  /// "Walk-in" rather than a blank line. A missing customer is a fact about the bill, and
  /// an empty space looks like a rendering fault.
  String _who() {
    final String? name = bill.customerName?.trim();
    final String? phone = bill.customerPhone;
    final bool hasName = name != null && name.isNotEmpty;
    final bool hasPhone = phone != null && phone.trim().isNotEmpty;
    if (hasName && hasPhone) {
      return '$name  ·  ${CustomerPhone.forDisplay(phone)}';
    }
    if (hasName) {
      return name;
    }
    if (hasPhone) {
      return CustomerPhone.forDisplay(phone);
    }
    return 'Walk-in';
  }
}
