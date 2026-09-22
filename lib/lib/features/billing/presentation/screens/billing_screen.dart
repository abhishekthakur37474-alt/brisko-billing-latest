import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/money/money_display.dart';
import '../../domain/models/cart.dart';
import '../controllers/billing_controller.dart';
import '../widgets/billing_category_navigation.dart';
import '../widgets/billing_status_views.dart';
import '../widgets/cart_panel.dart';
import '../widgets/item_configuration_panel.dart';
import '../widgets/menu_item_grid.dart';

/// Order entry: browse the menu, configure an item, build the bill.
///
/// ## Structure
///
/// Three panes on a counter display: categories, the items of the selected category,
/// and the bill. Choosing an item replaces the item pane with
/// [ItemConfigurationPanel] so sizes and customisations are chosen in place, with the
/// bill still in view. Narrow screens get the categories as a chip strip and reach the
/// bill through a summary bar.
///
/// ## Where the logic is
///
/// This screen reads [BillingController] and dispatches intents to it. It holds no
/// menu data, computes no price and contains no rule about what may be selected.
///
/// Settlement is deliberately absent: this step ends at the subtotal.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred until this frame is on screen. The controller announces that it has
    // started loading the moment it is asked, and notifying a listener while the
    // framework is still building is not allowed.
    //
    // The controller is app-scoped so the cart survives a switch to another section,
    // and it ignores this call once the menu is loaded.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      final BillingController controller = context.read<BillingController>();
      // First open loads the menu; a later return to this section re-reads it, so a
      // change made in menu management is reflected at the counter. The cart survives
      // both, because it lives on the app-scoped controller rather than this widget.
      if (controller.isMenuReady) {
        unawaited(controller.reloadMenu());
      } else {
        unawaited(controller.ensureMenuLoaded());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();

    if (!controller.isMenuReady) {
      return const BillingLoadingView(message: 'Loading the menu');
    }

    // A failure with nothing loaded is a dead end, so it takes the whole pane and
    // offers the retry. A failure with a menu already on screen is shown as a strip
    // instead, so the bill in progress stays usable.
    final String? errorMessage = controller.errorMessage;
    if (errorMessage != null && controller.categories.isEmpty) {
      return BillingErrorView(
        message: errorMessage,
        onRetry: controller.loadMenu,
      );
    }

    if (controller.categories.isEmpty) {
      return const BillingEmptyView(
        icon: Icons.menu_book_outlined,
        title: 'The menu is empty',
        subtitle: 'Add categories and items in the Menu section first.',
      );
    }

    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    return isWide ? const _WideLayout() : const _NarrowLayout();
  }
}

/// Counter and desktop layout: categories, items and the bill side by side.
class _WideLayout extends StatelessWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const <Widget>[
        BillingCategoryRail(),
        VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: <Widget>[
              _ErrorStrip(),
              Expanded(child: _ItemPane()),
            ],
          ),
        ),
        VerticalDivider(width: 1),
        SizedBox(width: CartPanel.width, child: CartPanel()),
      ],
    );
  }
}

/// Narrow layout: the bill moves into a sheet behind a summary bar.
class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const <Widget>[
        _ErrorStrip(),
        BillingCategoryStrip(),
        Divider(height: 1),
        Expanded(child: _ItemPane()),
        Divider(height: 1),
        _CartSummaryBar(),
      ],
    );
  }
}

/// Either the item grid or, once an item is chosen, its configuration.
class _ItemPane extends StatelessWidget {
  const _ItemPane();

  @override
  Widget build(BuildContext context) {
    final bool isConfiguring = context.select<BillingController, bool>(
      (BillingController controller) => controller.isConfiguring,
    );

    return isConfiguring
        ? const ItemConfigurationPanel()
        : const MenuItemGrid();
  }
}

/// Non-blocking report of a failure that happened while the screen was usable.
class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip();

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final String? message = controller.errorMessage;

    if (message == null || controller.categories.isEmpty) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            IconButton(
              onPressed: controller.dismissError,
              icon: const Icon(Icons.close, size: 16),
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

/// Narrow-layout footer: the running subtotal, tapped to open the bill.
class _CartSummaryBar extends StatelessWidget {
  const _CartSummaryBar();

  @override
  Widget build(BuildContext context) {
    final Cart cart = context.select<BillingController, Cart>(
      (BillingController controller) => controller.cart,
    );
    final ThemeData theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: cart.isEmpty ? null : () => _openCart(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SafeArea(
            top: false,
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.receipt_long_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cart.isEmpty
                        ? 'No items yet'
                        : '${cart.itemCount} '
                              '${cart.itemCount == 1 ? 'item' : 'items'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  cart.subtotal.formatted,
                  style: theme.textTheme.titleMedium,
                ),
                if (cart.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.expand_less,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openCart(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext _) {
        return const FractionallySizedBox(
          heightFactor: 0.85,
          child: CartPanel(),
        );
      },
    );
  }
}
