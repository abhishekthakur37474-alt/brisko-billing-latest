import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../controllers/checkout_controller.dart';

/// Last step before the money is taken.
///
/// Everything on this step is a restatement, deliberately: it is the page the cashier
/// reads back to the customer. Nothing here can be edited, and going back is always
/// available until the charge is confirmed.
class CheckoutConfirmStep extends StatelessWidget {
  const CheckoutConfirmStep({super.key});

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);
    final PaymentMethod method = controller.paymentMethod!;
    final String? errorMessage = controller.errorMessage;
    final String? reference = controller.reference.trim().isEmpty
        ? null
        : controller.reference.trim();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: <Widget>[
        Text(
          'Collect',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          controller.amountPayable.formatted,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: <Widget>[
              _ConfirmRow(label: 'Method', value: method.label),
              _ConfirmRow(
                label: 'Order type',
                value: controller.orderType.label,
              ),
              _ConfirmRow(
                label: 'Customer',
                // The stored form, not the keystrokes. This is the last screen before
                // the money is taken, so it shows the number the bill will actually
                // carry.
                value: _customerLabel(controller),
              ),
              _ConfirmRow(
                label: 'Kitchen slip',
                value: controller.printKitchenSlip ? 'Print' : 'Do not print',
              ),
              if (reference != null)
                _ConfirmRow(label: 'Reference', value: reference),
              if (method == PaymentMethod.cash) ...<Widget>[
                _ConfirmRow(
                  label: 'Cash tendered',
                  value: controller.cashTender.tendered.formatted,
                ),
                _ConfirmRow(
                  label: 'Change to give',
                  value: controller.changeDue.formatted,
                  emphasise: !controller.changeDue.isZero,
                ),
              ],
            ],
          ),
        ),
        if (errorMessage != null) ...<Widget>[
          const SizedBox(height: 16),
          _FailureNotice(message: errorMessage),
        ],
        const SizedBox(height: 24),
        Text(
          'Confirming writes the bill to this terminal and records the payment. '
          'Nothing is sent anywhere else.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// The customer as the bill will record them.
  ///
  /// The name is what the bill shows. The number is how they are found again.
  static String _customerLabel(CheckoutController controller) {
    final String name = controller.trimmedCustomerName;
    if (name.isNotEmpty) {
      return name;
    }
    final String? stored = controller.normalisedCustomerPhone;
    if (stored == null) {
      return 'Walk-in';
    }
    return CustomerPhone.forDisplay(stored);
  }
}

class _ConfirmRow extends StatelessWidget {
  const _ConfirmRow({
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
          Text(
            value,
            style: emphasise
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// Reports a settlement that did not happen.
///
/// Says plainly that nothing was written, because the cashier's next question is
/// whether to ring the bill up again. The bill is still here and the charge can simply
/// be confirmed once more.
class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 20,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'The bill was not settled',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Nothing was recorded. The bill is unchanged and can be '
                    'confirmed again.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: context.read<CheckoutController>().dismissError,
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onErrorContainer,
            ),
          ],
        ),
      ),
    );
  }
}
