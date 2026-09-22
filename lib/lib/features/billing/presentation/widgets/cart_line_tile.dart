import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cart_line.dart';
import '../controllers/billing_controller.dart';

/// One line of the bill in the cart panel.
///
/// Reads the line's own snapshots. It does not look the item up in the menu, which is
/// what keeps a displayed line stable while the menu underneath it changes.
class CartLineTile extends StatelessWidget {
  const CartLineTile({required this.line, super.key});

  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BillingController controller = context.read<BillingController>();
    final String? optionsSummary = line.optionsSummary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  line.displayName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(line.lineTotal.formatted, style: theme.textTheme.titleSmall),
              IconButton(
                onPressed: () => controller.removeLine(line.id),
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove ${line.displayName}',
              ),
            ],
          ),
          if (optionsSummary != null)
            Padding(
              padding: const EdgeInsets.only(right: 48, bottom: 2),
              child: Text(
                optionsSummary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              _QuantityStepper(line: line),
              const SizedBox(width: 12),
              Text(
                '${line.unitPrice.formatted} each',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BillingController controller = context.read<BillingController>();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _StepperButton(
            icon: Icons.remove,
            tooltip: 'Reduce the quantity',
            // One is the floor: removing a line is a separate, deliberate action,
            // so the control is disabled rather than silently dropping the line.
            onPressed: line.quantity > 1
                ? () => controller.decreaseQuantity(line.id)
                : null,
          ),
          SizedBox(
            width: 32,
            child: Text(
              '${line.quantity}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
          ),
          _StepperButton(
            icon: Icons.add,
            tooltip: 'Increase the quantity',
            onPressed: line.quantity < Cart.maxLineQuantity
                ? () => controller.increaseQuantity(line.id)
                : null,
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;

  final String tooltip;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
    );
  }
}
