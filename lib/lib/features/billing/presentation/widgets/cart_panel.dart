import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../app/routes/app_routes.dart';
import '../../../../core/money/money_display.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cart_line.dart';
import '../controllers/billing_controller.dart';
import 'billing_status_views.dart';
import 'cart_line_tile.dart';

/// The bill being built: its lines, their quantities, and the subtotal.
///
/// Every amount shown here is read from the cart, which computes it in integer paise
/// through [Money]. Nothing is summed in this file and nothing is read back from the
/// text on screen.
class CartPanel extends StatelessWidget {
  const CartPanel({super.key});

  /// Fits the longest seeded item name plus a size, a quantity stepper and a total.
  static const double width = 372;

  @override
  Widget build(BuildContext context) {
    final Cart cart = context.select<BillingController, Cart>(
      (BillingController controller) => controller.cart,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _CartHeader(cart: cart),
        const Divider(height: 1),
        Expanded(
          child: cart.isEmpty
              ? const BillingEmptyView(
                  icon: Icons.receipt_long_outlined,
                  title: 'No items yet',
                  subtitle: 'Choose an item from the menu to start the bill.',
                )
              : ListView.separated(
                  itemCount: cart.lineCount,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final CartLine line = cart.lines[index];
                    return CartLineTile(
                      key: ValueKey<String>(line.id),
                      line: line,
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        _CartSummary(cart: cart, theme: theme),
      ],
    );
  }
}

class _CartHeader extends StatelessWidget {
  const _CartHeader({required this.cart});

  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Current bill', style: theme.textTheme.titleMedium),
                Text(
                  cart.isEmpty
                      ? 'Empty'
                      : '${cart.lineCount} '
                            '${cart.lineCount == 1 ? 'line' : 'lines'} '
                            '\u00b7 ${cart.itemCount} '
                            '${cart.itemCount == 1 ? 'item' : 'items'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: cart.isEmpty
                ? null
                : () => _confirmClear(context, cart.lineCount),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  /// Confirms before discarding a part-built bill.
  ///
  /// Rebuilding a ten-line order because of a stray tap is the kind of mistake that
  /// holds up a queue, so the destructive action asks first.
  Future<void> _confirmClear(BuildContext context, int lineCount) async {
    final BillingController controller = context.read<BillingController>();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Clear this bill?'),
          content: Text(
            'All $lineCount ${lineCount == 1 ? 'line' : 'lines'} will be '
            'removed. This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep the bill'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );

    if (confirmed ?? false) {
      controller.clearCart();
    }
  }
}

class _CartSummary extends StatelessWidget {
  const _CartSummary({required this.cart, required this.theme});

  final Cart cart;

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('Subtotal', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                cart.subtotal.formatted,
                style: theme.textTheme.headlineSmall,
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            // The cart is what makes a bill; there is nothing to settle without
            // one. Opening checkout does not commit anything, and backing out of
            // it leaves this cart exactly as it is.
            onPressed: cart.isEmpty
                ? null
                : () => Navigator.of(context).pushNamed(AppRoutes.checkout),
            icon: const Icon(Icons.point_of_sale),
            // "Checkout" rather than "Charge": this opens the settlement flow, it
            // does not take any money. The charge is confirmed at the end of it.
            label: Text('Checkout ${cart.subtotal.formatted}'),
          ),
          const SizedBox(height: 8),
          const _HoldRow(),
          const _HeldNotice(),
          const SizedBox(height: 8),
          // The subtotal is all this panel can honestly show. A discount is entered at
          // checkout, on the bill it applies to, and GST is charged on what is left after
          // it — so neither figure exists until settlement opens. Saying so is better than
          // showing a total here that the next screen changes.
          Text(
            'Discount and GST are applied at checkout.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The two counter actions that do not take money: put the bill aside, or open the bills
/// already put aside.
///
/// Hold is disabled on an empty bill — there is nothing to hold — while Held bills is
/// always available, because the list is worth reaching whether or not a bill is in
/// progress.
class _HoldRow extends StatelessWidget {
  const _HoldRow();

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final bool canHold = controller.canHold && !controller.isHolding;

    return Row(
      children: <Widget>[
        Expanded(
          child: TextButton.icon(
            onPressed: canHold ? controller.holdCart : null,
            icon: const Icon(Icons.pause_circle_outline, size: 18),
            label: const Text('Hold'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextButton.icon(
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.heldBills),
            icon: const Icon(Icons.list_alt_outlined, size: 18),
            label: const Text('Held bills'),
          ),
        ),
      ],
    );
  }
}

/// The confirmation for a bill just held, or the reason a hold failed, or nothing.
///
/// A held bill's confirmation is dismissible: the cashier has seen it and is starting the
/// next bill. A failed hold shows its message so the cart the cashier still has stays
/// explained rather than silently unheld.
class _HeldNotice extends StatelessWidget {
  const _HeldNotice();

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final ThemeData theme = Theme.of(context);

    final String? error = controller.holdError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Dismiss',
              onPressed: controller.dismissHoldError,
            ),
          ],
        ),
      );
    }

    final String? notice = controller.heldNotice;
    if (notice == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.check_circle_outline,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(notice, style: theme.textTheme.bodySmall)),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            onPressed: controller.dismissHeldNotice,
          ),
        ],
      ),
    );
  }
}
