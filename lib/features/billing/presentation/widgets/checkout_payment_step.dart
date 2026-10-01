import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../domain/models/cash_tender.dart';
import '../controllers/checkout_controller.dart';

/// Second step: how the bill is being paid, and for cash, what was handed over.
///
/// The amount payable is fixed by the bill. Cash and non-cash both record that
/// amount: cash is tendered exactly when the method is chosen, so there is no
/// keypad.
class CheckoutPaymentStep extends StatelessWidget {
  const CheckoutPaymentStep({super.key});

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);
    final PaymentMethod? method = controller.paymentMethod;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: <Widget>[
        Text(
          'Amount payable',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          controller.amountPayable.formatted,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 24),
        Text('Payment method', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _PaymentMethodChoices(),
        const SizedBox(height: 24),
        if (method == PaymentMethod.cash)
          const _CashSection()
        else if (method != null)
          const _NonCashSection()
        else
          Text(
            'Choose a method to continue.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _PaymentMethodChoices extends StatelessWidget {
  const _PaymentMethodChoices();

  /// Icon per method. Presentation only; the enum decides what exists.
  static IconData _icon(PaymentMethod method) => switch (method) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.upi => Icons.qr_code_2,
    PaymentMethod.card => Icons.credit_card,
    PaymentMethod.other => Icons.more_horiz,
  };

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final PaymentMethod method in PaymentMethod.values)
          ChoiceChip(
            avatar: Icon(_icon(method), size: 18),
            label: Text(method.label),
            selected: controller.paymentMethod == method,
            onSelected: (bool _) =>
                context.read<CheckoutController>().selectPaymentMethod(method),
          ),
      ],
    );
  }
}

/// Cash counting: what was handed over, what goes back.
class _CashSection extends StatelessWidget {
  const _CashSection();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final CashTender tender = controller.cashTender;
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Cash received', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text('Tendered', style: theme.textTheme.bodyMedium),
                    const Spacer(),
                    Text(
                      tender.tendered.formatted,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                // One line, not two: either change is owed or the tender is short,
                // and showing both invites reading the wrong one.
                Row(
                  children: <Widget>[
                    Text(
                      tender.isSufficient ? 'Change' : 'Still needed',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const Spacer(),
                    Text(
                      tender.isSufficient
                          ? tender.change.formatted
                          : tender.shortfall.formatted,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: tender.isSufficient
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// UPI, card or anything else: the amount is the bill, and only a reference is taken.
class _NonCashSection extends StatefulWidget {
  const _NonCashSection();

  @override
  State<_NonCashSection> createState() => _NonCashSectionState();
}

class _NonCashSectionState extends State<_NonCashSection> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: context.read<CheckoutController>().reference,
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);
    final PaymentMethod method = controller.paymentMethod!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${method.label} of ${controller.amountPayable.formatted} will be '
          'recorded. There is no change to give.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _field,
          decoration: InputDecoration(
            labelText: 'Reference',
            hintText: switch (method) {
              PaymentMethod.upi => 'UPI transaction id',
              PaymentMethod.card => 'Approval code',
              PaymentMethod.other => 'What it was',
              PaymentMethod.cash => '',
            },
            prefixIcon: const Icon(Icons.receipt_outlined),
            helperText: 'Optional, but worth keeping for a later dispute.',
          ),
          onChanged: context.read<CheckoutController>().setReference,
        ),
      ],
    );
  }
}
