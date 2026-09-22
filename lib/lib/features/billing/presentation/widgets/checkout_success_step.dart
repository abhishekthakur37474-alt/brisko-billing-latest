import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/domain/models/order.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../printing/domain/models/sale_print_run.dart';
import '../controllers/checkout_controller.dart';

/// The settled bill: its number, what was collected, and what to hand back.
///
/// Reached only after the write committed, so everything shown here is on disk. The
/// order number comes from the persisted order rather than from anything computed on
/// screen, which is why it is safe to read out to the customer.
class CheckoutSuccessStep extends StatelessWidget {
  const CheckoutSuccessStep({required this.onDone, super.key});

  /// Leaves the flow and returns to an empty billing screen.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);
    final Order? order = controller.settledOrder;

    if (order == null) {
      return const SizedBox.shrink();
    }

    final bool hasChange =
        controller.paymentMethod == PaymentMethod.cash &&
        !controller.changeDue.isZero;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                size: 44,
                color: AppColors.success,
              ),
              const SizedBox(height: 16),
              Text(
                'Bill settled',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Order ${order.orderNumber}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Card(
                child: Column(
                  children: <Widget>[
                    _SettledRow(
                      label: 'Collected',
                      value: order.totalAmount.formatted,
                    ),
                    _SettledRow(
                      label: 'Method',
                      value: controller.paymentMethod!.label,
                    ),
                    _SettledRow(
                      label: 'Order type',
                      value: order.orderType.label,
                    ),
                    if (controller.hasCustomerName)
                      _SettledRow(
                        label: 'Customer',
                        value: controller.trimmedCustomerName,
                      ),
                    if (controller.isCustomerPhoneComplete)
                      _SettledRow(
                        label: 'Phone',
                        value: CustomerPhone.forDisplay(
                          controller.normalisedCustomerPhone!,
                        ),
                      ),
                    _SettledRow(label: 'Status', value: order.status.label),
                  ],
                ),
              ),
              if (hasChange) ...<Widget>[
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.currency_exchange,
                          size: 20,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Give change',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          controller.changeDue.formatted,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const _PrintingStatus(),
              const _InventoryStatus(),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onDone,
                icon: const Icon(Icons.add),
                label: const Text('Start a new bill'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What happened to the receipt and the kitchen slip.
///
/// Deliberately below the settled-bill card and visually separate from it. The money is
/// collected and recorded; this is about paper. The failure wording leads with that,
/// because the cashier's first instinct on seeing red is to charge the customer again.
class _PrintingStatus extends StatelessWidget {
  const _PrintingStatus();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);

    // Deliberately not a spinner. Printing starts after the success screen is already
    // on display and finishes in well under a second, so an animation would be a flash
    // of movement on a screen the cashier is reading. A static line says the same thing
    // and leaves the screen still.
    if (controller.isPrinting) {
      return _PrintingNote(
        icon: Icons.print_outlined,
        message: controller.printKitchenSlip
            ? 'Printing the bill and the kitchen slip'
            : 'Printing the bill',
      );
    }

    if (controller.isPrinted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PrintingNote(
            icon: Icons.print_outlined,
            colour: AppColors.success,
            message: controller.printKitchenSlip
                ? 'Bill and kitchen slip printed'
                : 'Bill printed',
          ),
          const _ReprintActions(),
        ],
      );
    }

    final String? message = controller.printMessage;
    if (message == null) {
      // Nothing has been attempted, or the notice was dismissed. The paperwork can still
      // be sent again: the bill is on disk, and that is all a reprint needs.
      return const _ReprintActions();
    }

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.print_disabled_outlined,
                  size: 20,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // The money is safe. Said first, and in the strongest style
                    // available, so it is read before the reason.
                    SalePrintRun.paidButNotPrinted,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 12),
            // Stacked rather than side by side: both labels are sentences, and on a
            // narrow till they would not fit on one line.
            FilledButton.icon(
              onPressed: controller.retryPrinting,
              icon: const Icon(Icons.refresh),
              label: const Text('Try printing again'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: controller.dismissPrintFailure,
              child: const Text('Continue without printing'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sending the paperwork again, for the copy that jammed or was thrown away.
///
/// ## Why these are safe to press at any time
///
/// Both rebuild their document from the committed order and send it. Neither writes
/// anything: no second order, no second payment, no second kitchen ticket, no stock
/// movement and no change to the day's takings. Pressing one twice costs paper and
/// nothing else, which is why there is no confirmation in front of them.
///
/// Kept quiet — text buttons under the status line rather than the primary action, because
/// the primary action on this screen is starting the next bill and there is usually a queue.
class _ReprintActions extends StatelessWidget {
  const _ReprintActions();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();

    if (!controller.canReprint) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        children: <Widget>[
          TextButton.icon(
            onPressed: controller.reprintReceipt,
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('Print receipt again'),
          ),
          if (controller.printKitchenSlip)
            TextButton.icon(
              onPressed: controller.reprintKitchenSlips,
              icon: const Icon(Icons.soup_kitchen_outlined, size: 18),
              label: const Text('Print kitchen slip again'),
            ),
        ],
      ),
    );
  }
}

/// What happened to the stock this bill consumed.
///
/// Silent when the deduction was clean, which is the normal case and needs no words. It
/// appears only when the owner has something to do: an ingredient was short, or a sold
/// item has no recipe and so accounted for nothing.
///
/// Deliberately a quiet note rather than an error, and deliberately with no retry
/// button. Nothing here is the cashier's problem: the money is collected, the bill is
/// written and the kitchen has its slip. The bill is already on the owner's list in
/// Inventory, where it can be retried once the shelf has been counted, so pressing
/// something at the till would only interrupt the queue.
class _InventoryStatus extends StatelessWidget {
  const _InventoryStatus();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);
    final String? message = controller.inventoryMessage;

    if (message == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.inventory_2_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                onPressed: controller.dismissInventoryNotice,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Dismiss stock note',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-line printing note, centred under the settled-bill card.
class _PrintingNote extends StatelessWidget {
  const _PrintingNote({required this.icon, required this.message, this.colour});

  final IconData icon;

  final String message;

  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color resolved = colour ?? theme.colorScheme.onSurfaceVariant;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 16, color: resolved),
        const SizedBox(width: 8),
        // Flexible so a longer message wraps rather than overflowing the card.
        Flexible(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: resolved),
          ),
        ),
      ],
    );
  }
}

class _SettledRow extends StatelessWidget {
  const _SettledRow({required this.label, required this.value});

  final String label;

  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
