import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money.dart';
import '../../../../core/money/money_display.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/domain/services/manager_auth_service.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../customers/domain/repositories/customer_repository.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../payments/domain/models/refund.dart';
import '../../../payments/domain/models/refundable_bill.dart';
import '../../../payments/domain/repositories/payment_repository.dart';
import '../../../payments/domain/repositories/refund_repository.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../../printing/domain/services/print_service.dart';
import '../../domain/models/bill_line_snapshot.dart';
import '../../domain/models/order.dart';
import '../../domain/models/order_item_option.dart';
import '../../domain/repositories/order_repository.dart';
import '../controllers/bill_detail_controller.dart';

/// A stored bill, opened from a customer's history.
///
/// ## What is on screen
///
/// The persisted document and nothing else: the number, when it was taken, the customer,
/// the order type, every line with its size, its options, its quantity, its unit price
/// and its line total, then the discount, the tax, the grand total and how it was paid.
///
/// ## What is not
///
/// A current price. There is no menu lookup anywhere behind this widget, which is what
/// lets a bill from six months ago open correctly after the dish has been renamed,
/// repriced or removed from the menu altogether.
///
/// This widget contains no SQL and no business rule. It reads [BillDetailController].
class BillDetailView extends StatelessWidget {
  const BillDetailView({required this.orderId, super.key});

  /// Opens the bill in a dialog.
  ///
  /// Its own provider scope, so the controller is built, loaded and disposed with the
  /// dialog and the screen behind it keeps whatever it had loaded.
  static Future<void> show(BuildContext context, {required String orderId}) {
    final OrderRepository orders = context.read<OrderRepository>();
    final PaymentRepository payments = context.read<PaymentRepository>();
    final CustomerRepository customers = context.read<CustomerRepository>();
    final RefundRepository refunds = context.read<RefundRepository>();
    final ManagerAuthService managerAuth = context.read<ManagerAuthService>();
    final PrintService printService = context.read<PrintService>();

    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return ChangeNotifierProvider<BillDetailController>(
          create: (BuildContext _) {
            final BillDetailController controller = BillDetailController(
              orderId: orderId,
              orderRepository: orders,
              paymentRepository: payments,
              customerRepository: customers,
              refundRepository: refunds,
              managerAuthService: managerAuth,
              printService: printService,
            );
            // Not awaited: the first frame shows the loading state while the read runs.
            unawaited(controller.load());
            return controller;
          },
          child: BillDetailView(orderId: orderId),
        );
      },
    );
  }

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final BillDetailController controller = context
        .watch<BillDetailController>();

    return AlertDialog(
      title: Text(
        controller.orderNumber == null
            ? 'Bill'
            : 'Bill ${controller.orderNumber}',
      ),
      content: SizedBox(width: 520, child: _Body(controller: controller)),
      actions: <Widget>[
        // Reprinting is offered on every bill that loaded, and it is the only action here
        // that changes nothing whatsoever: it rebuilds the documents from these same
        // committed rows and sends them again. No second order, no second payment, no
        // second kitchen ticket, no stock movement and no change to a report.
        if (controller.canReprint) ...<Widget>[
          TextButton.icon(
            onPressed: controller.reprintReceipt,
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('Reprint receipt'),
          ),
          TextButton.icon(
            onPressed: controller.reprintKitchenSlips,
            icon: const Icon(Icons.soup_kitchen_outlined, size: 18),
            label: const Text('Reprint KOT'),
          ),
        ],
        // Cancelling a live bill. Offered only for a bill that is not yet settled and not
        // already cancelled — a completed sale is refunded, not cancelled. The business
        // rules live in the repository; this button only reaches them.
        if (controller.canCancel)
          TextButton(
            onPressed: controller.isCancelling
                ? null
                : () => _confirmCancel(context, controller),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Cancel bill'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        // Offered only once the bill has been read and only for a bill that could actually be
        // refunded. A disabled button beside every unrefundable bill would invite a tap that
        // can never work; the reason is written into the panel above instead.
        if (controller.canRefund)
          FilledButton(
            onPressed: controller.isRefunding
                ? null
                : () => _confirmRefund(context, controller),
            child: const Text('Refund'),
          ),
      ],
    );
  }

  /// Asks before cancelling, then cancels.
  ///
  /// A separate dialog so the action cannot be reached by a stray tap, and one that names
  /// what a cancellation does and does not do: the record is kept, outstanding kitchen work
  /// is stopped, and no money moves. The outcome is rendered in place by the notice inside
  /// the bill rather than a snack bar.
  Future<void> _confirmCancel(
    BuildContext context,
    BillDetailController controller,
  ) async {
    final String number = controller.orderNumber ?? '';

    final TextEditingController passwordController = TextEditingController();
    final TextEditingController reasonController = TextEditingController();
    final ValueNotifier<bool> isObscured = ValueNotifier<bool>(true);

    try {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text('Cancel bill $number?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'The bill is kept on the record as cancelled and any outstanding '
                  'kitchen work is stopped. No payment is reversed and stock is not '
                  'put back. This cannot be undone.',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<bool>(
                  valueListenable: isObscured,
                  builder: (context, obscured, child) {
                    return TextField(
                      controller: passwordController,
                      obscureText: obscured,
                      decoration: InputDecoration(
                        labelText: 'Manager Password',
                        suffixIcon: IconButton(
                          icon: Icon(obscured ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => isObscured.value = !obscured,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  decoration: const InputDecoration(
                    labelText: 'Reason (Optional)',
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Keep the bill'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Cancel the bill'),
              ),
            ],
          );
        },
      );

      if (confirmed ?? false) {
        await controller.cancel(
          password: passwordController.text,
          reason: reasonController.text.trim().isEmpty ? null : reasonController.text.trim(),
        );
      }
    } finally {
      passwordController.dispose();
      reasonController.dispose();
      isObscured.dispose();
    }
  }

  /// Asks before moving money, then refunds.
  ///
  /// The confirmation names the bill number and the exact amount, because those are the two
  /// things whoever taps this has to check against the paper in front of them. It is a
  /// separate dialog rather than an inline toggle so that the action cannot be reached by a
  /// stray tap on a scrolling list.
  ///
  /// The outcome is rendered in place by the panel inside the bill, not by a snack bar: this
  /// dialog may well be closed before a snack bar would have been read, and "did the money go
  /// back" is not a question to answer transiently.
  Future<void> _confirmRefund(
    BuildContext context,
    BillDetailController controller,
  ) async {
    final RefundableBill? bill = controller.refundable;
    if (bill == null) {
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Refund bill ${bill.orderNumber}?'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${bill.refundableAmount.formatted} will be recorded as '
                'handed back by ${bill.paymentMethod?.label ?? 'the original '
                        'payment method'}.',
              ),
              const SizedBox(height: 12),
              // Named rather than implied. Someone refunding a bill is entitled to know that
              // the sale stays on the record and that the stock does not come back.
              Text(
                'The original bill and its payment are kept exactly as they '
                'are. Stock is not put back, and the kitchen record is not '
                'changed. This cannot be undone.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep the sale'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Refund ${bill.refundableAmount.formatted}'),
            ),
          ],
        );
      },
    );

    if (confirmed ?? false) {
      // The result is not inspected: the controller records both outcomes and the panel
      // renders whichever happened. Awaited so an uncaught error here would surface as one.
      await controller.refund();
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final BillDetailController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (controller.hasError) {
      return _BillNotice(
        icon: Icons.error_outline,
        message: controller.errorMessage!,
        onRetry: controller.retry,
      );
    }

    if (controller.isMissing) {
      return const _BillNotice(
        icon: Icons.receipt_long_outlined,
        message:
            'That bill is no longer on this terminal, so there is nothing to '
            'show.',
      );
    }

    final Order order = controller.order!;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _Header(controller: controller, order: order),
          const Divider(height: 24),
          for (final BillLineSnapshot line in controller.lines)
            _LineRow(line: line),
          if (controller.lines.isEmpty)
            Text(
              'This bill has no lines stored against it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const Divider(height: 24),
          _Totals(controller: controller, order: order),
          if (controller.refundable != null) ...<Widget>[
            const Divider(height: 24),
            _RefundPanel(controller: controller),
          ],
          _ReprintStatus(controller: controller),
          _CancelStatus(controller: controller),
        ],
      ),
    );
  }
}

/// Whether the last cancellation went through, and why it did not if it failed.
///
/// Silent until a cancellation has been attempted. Separate from the refund and reprint
/// notices: a refused cancellation is a fact about that one action, and the bill behind it
/// is still perfectly readable.
class _CancelStatus extends StatelessWidget {
  const _CancelStatus({required this.controller});

  final BillDetailController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (controller.isCancelling) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text('Cancelling the bill…', style: theme.textTheme.bodySmall),
      );
    }

    if (controller.didCancel) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 18,
              color: AppColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'This bill has been cancelled. The record is kept and no '
                'money was reversed.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.success,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (!controller.hasCancelError) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.cancelError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          IconButton(
            onPressed: controller.dismissCancelError,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// How the last reprint went.
///
/// Silent until something has been sent, because a bill nobody has asked to reprint has
/// nothing to report. Deliberately separate from the refund panel and from the bill itself: a
/// printer that would not take the paper says nothing about the sale or the money, and it must
/// not look as though it does.
class _ReprintStatus extends StatelessWidget {
  const _ReprintStatus({required this.controller});

  final BillDetailController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (controller.isReprinting) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          'Sending to the printer…',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final String? message = controller.reprintMessage;
    if (message == null) {
      return const SizedBox.shrink();
    }

    final Color colour = controller.didReprint
        ? AppColors.success
        : theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            controller.didReprint
                ? Icons.check_circle_outline
                : Icons.print_disabled_outlined,
            size: 18,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: colour),
            ),
          ),
          IconButton(
            onPressed: controller.dismissReprintMessage,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// What has been refunded on this bill, what could be, and how the last attempt went.
///
/// Always present for a bill that was read, even when nothing can be refunded, because "how
/// much of this bill is still refundable" is a question the record answers and a blank space
/// does not. The reason a refund is unavailable is written out here rather than hidden behind
/// a disabled button.
class _RefundPanel extends StatelessWidget {
  const _RefundPanel({required this.controller});

  final BillDetailController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RefundableBill bill = controller.refundable!;
    final Refund? justRefunded = controller.justRefunded;
    final Refund? existing = bill.existingRefund;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Refund', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        // The three figures a refund decision is made from, in the order they relate:
        // what came in, what has gone back, what is left.
        _AmountRow(label: 'Paid', amount: bill.paidAmount),
        _AmountRow(label: 'Already refunded', amount: bill.refundedAmount),
        _AmountRow(
          label: 'Refundable now',
          amount: bill.refundableAmount,
          emphasise: true,
        ),
        if (existing != null) ...<Widget>[
          const SizedBox(height: 8),
          _DetailRow(
            label: 'Refunded on',
            value: PrintTimestamp.stamp(existing.createdAt),
          ),
          _DetailRow(label: 'Refunded by', value: existing.paymentMethod.label),
          if (existing.reason != null)
            _DetailRow(label: 'Reason', value: existing.reason!),
        ],
        if (bill.isUnderpaid) ...<Widget>[
          const SizedBox(height: 8),
          // Stated rather than smoothed over. The collected figure is what limits a refund,
          // so a reader comparing it to the grand total above needs to know why they differ.
          Text(
            'The amount collected does not match the grand total on this bill. '
            'A refund is limited to what was collected.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (justRefunded != null) ...<Widget>[
          const SizedBox(height: 12),
          _RefundNotice(
            icon: Icons.check_circle_outline,
            colour: theme.colorScheme.primary,
            message:
                '${justRefunded.amount.formatted} refunded by '
                '${justRefunded.paymentMethod.label}. The original bill and '
                'payment are unchanged.',
          ),
        ],
        if (controller.hasRefundError) ...<Widget>[
          const SizedBox(height: 12),
          _RefundNotice(
            icon: Icons.error_outline,
            colour: theme.colorScheme.error,
            message: controller.refundError!,
            // Dismissing clears the notice and nothing else. The held request survives, so
            // tapping Refund again retries the same intent rather than starting a second.
            onDismiss: controller.dismissRefundError,
          ),
        ],
        if (controller.isRefunding) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Recording the refund…', style: theme.textTheme.bodySmall),
            ],
          ),
        ],
        if (controller.refundRefusal != null &&
            justRefunded == null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            controller.refundRefusal!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// The outcome of a refund attempt, said in place.
class _RefundNotice extends StatelessWidget {
  const _RefundNotice({
    required this.icon,
    required this.colour,
    required this.message,
    this.onDismiss,
  });

  final IconData icon;

  final Color colour;

  final String message;

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
        ),
        if (onDismiss != null)
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// Who, when, and how the order was taken.
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.order});

  final BillDetailController controller;

  final Order order;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailRow(
          label: 'Date and time',
          // Stored UTC, shown local: a bill taken at 2pm has to read as 2pm.
          value: PrintTimestamp.stamp(order.createdAt),
        ),
        _DetailRow(label: 'Order type', value: order.orderType.label),
        _DetailRow(
          label: 'Customer',
          value: controller.customerName ?? 'Walk-in',
        ),
        if (controller.customerPhone != null)
          _DetailRow(
            label: 'Phone',
            value: CustomerPhone.forDisplay(controller.customerPhone!),
          ),
        _DetailRow(label: 'Status', value: order.status.label),
        if (order.notes != null && order.notes!.trim().isNotEmpty)
          _DetailRow(label: 'Note', value: order.notes!.trim()),
      ],
    );
  }
}

/// One stored line: name, size, options, quantity, unit price, line total.
class _LineRow extends StatelessWidget {
  const _LineRow({required this.line});

  final BillLineSnapshot line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  // The name and size as they were when sold, not as the menu reads
                  // today.
                  line.displayName,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${line.quantity} x ${line.unitPrice.formatted}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(
                  line.lineTotal.formatted,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          for (final OrderItemOption option in line.options)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      option.quantity > 1
                          ? '+ ${option.optionNameSnapshot} x${option.quantity}'
                          : '+ ${option.optionNameSnapshot}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    option.totalAmount.formattedAsAddition,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (line.item.notes != null && line.item.notes!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                line.item.notes!.trim(),
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

/// The money, as it was recorded.
class _Totals extends StatelessWidget {
  const _Totals({required this.controller, required this.order});

  final BillDetailController controller;

  final Order order;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PaymentMethod? method = controller.paymentMethod;
    final String? reference = controller.paymentReference;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AmountRow(label: 'Subtotal', amount: order.subtotal),
        if (!order.discountAmount.isZero)
          _AmountRow(label: 'Discount', amount: -order.discountAmount),
        if (!order.taxAmount.isZero)
          _AmountRow(label: 'Tax', amount: order.taxAmount),
        _AmountRow(
          label: 'Grand total',
          amount: order.totalAmount,
          emphasise: true,
        ),
        const SizedBox(height: 8),
        _DetailRow(
          label: 'Paid by',
          value: method?.label ?? 'No settled payment recorded',
        ),
        if (reference != null) _DetailRow(label: 'Reference', value: reference),
        if (!controller.isConsistent) ...<Widget>[
          const SizedBox(height: 8),
          // Said out loud rather than smoothed over. If the stored lines do not add up
          // to the stored subtotal, that is a fact about the record and whoever is
          // reading it needs to know before they quote a figure from it.
          Text(
            'The stored lines add up to ${controller.linesTotal.formatted}, '
            'which does not match the subtotal on this bill.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;

  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
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
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          Text(amount.formatted, style: style),
        ],
      ),
    );
  }
}

/// A bill that could not be shown, with the reason.
class _BillNotice extends StatelessWidget {
  const _BillNotice({required this.icon, required this.message, this.onRetry});

  final IconData icon;

  final String message;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}
