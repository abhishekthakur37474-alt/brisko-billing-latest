import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/presentation/widgets/bill_detail_view.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../domain/models/customer_phone.dart';
import '../controllers/customer_history_controller.dart';
import 'customer_notices.dart';

/// One customer: their number, their totals, and every bill they have been given.
///
/// Reads [CustomerHistoryController] and nothing else. Every figure on screen was stored
/// when the bill was settled, which is what lets this pane stay correct after the menu is
/// repriced or a dish is removed.
class CustomerHistoryView extends StatelessWidget {
  const CustomerHistoryView({this.onClose, super.key});

  /// Closes the pane, on layouts where it is dismissible.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final CustomerHistoryController controller = context
        .watch<CustomerHistoryController>();

    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.hasError) {
      return Center(
        child: CustomerErrorBanner(
          message: controller.errorMessage!,
          onRetry: controller.retry,
        ),
      );
    }

    if (controller.isMissing) {
      return const CustomerEmptyState(
        icon: Icons.person_off_outlined,
        title: 'That customer is no longer on this terminal',
        message: 'The record has been removed since the list was read.',
      );
    }

    return Column(
      children: <Widget>[
        _HistoryHeader(controller: controller, onClose: onClose),
        Expanded(child: _HistoryBody(controller: controller)),
      ],
    );
  }
}

/// The phone number and the three totals worth showing at a counter.
class _HistoryHeader extends StatelessWidget {
  const _HistoryHeader({required this.controller, this.onClose});

  final CustomerHistoryController controller;

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? name = controller.summary?.customer.name?.trim();
    final Order? recent = controller.mostRecentOrder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name == null || name.isEmpty
                          ? CustomerPhone.forDisplay(controller.phone ?? '')
                          : name,
                      style: theme.textTheme.titleLarge,
                    ),
                    if (name != null && name.isNotEmpty)
                      Text(
                        CustomerPhone.forDisplay(controller.phone ?? ''),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (controller.isLoading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (onClose != null)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close customer',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _Figure(
                label: 'Completed orders',
                value: '${controller.completedOrderCount}',
              ),
              _Figure(
                label: 'Total spent',
                // Net of anything handed back, which is what this customer has actually
                // paid. Equal to the billed figure until a refund exists, so an ordinary
                // record reads exactly as it did before.
                value: controller.netSpent.formatted,
              ),
              _Figure(
                label: 'Most recent',
                value: recent == null
                    ? '—'
                    : PrintTimestamp.stamp(recent.createdAt),
              ),
            ],
          ),
          // Both figures, once they differ. A single netted number would leave nobody able
          // to see that a reversal had happened at all, and the customer's visits and bills
          // below deliberately still show the refunded order.
          if (controller.hasRefunds) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Billed ${controller.totalSpent.formatted}, of which '
              '${controller.refundedTotal.formatted} was refunded.',
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

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;

  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({required this.controller});

  final CustomerHistoryController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isEmpty) {
      return const CustomerEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No bills against this number yet',
        message:
            'The record exists but no settled bill refers to it. One appears here '
            'as soon as a bill is taken with this number.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: controller.orders.length,
      itemBuilder: (BuildContext context, int index) {
        final Order order = controller.orders[index];
        return _OrderRow(
          order: order,
          itemSummary: controller.itemSummaryOf(order),
          paymentMethod: controller.paymentMethodOf(order),
        );
      },
    );
  }
}

/// One bill in the history. Tapping it opens the stored document.
class _OrderRow extends StatelessWidget {
  const _OrderRow({
    required this.order,
    required this.itemSummary,
    required this.paymentMethod,
  });

  final Order order;

  /// What the bill contained, from its stored line snapshots, or `null` if none.
  final String? itemSummary;

  /// How it was settled, or `null` when nothing is recorded against it.
  final PaymentMethod? paymentMethod;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => BillDetailView.show(context, orderId: order.id),
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Bill ${order.orderNumber}',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(
              // The persisted total. Never recomputed from the menu.
              order.totalAmount.formatted,
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
            if (itemSummary != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                itemSummary!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }

  /// When, how it was taken, and how it was paid.
  ///
  /// The status is named only when it is not an ordinary settled bill, so a reader is
  /// not asked to decode a label on every row. The payment method is omitted rather than
  /// guessed at when none is recorded.
  String _meta() {
    return <String>[
      // Stored UTC, shown local.
      PrintTimestamp.stamp(order.createdAt),
      order.orderType.label,
      if (paymentMethod != null) paymentMethod!.label,
      if (!order.status.countsTowardsSales) order.status.label,
    ].join('  ·  ');
  }
}
