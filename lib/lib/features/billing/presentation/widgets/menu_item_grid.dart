import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_type.dart';
import '../controllers/billing_controller.dart';
import 'billing_status_views.dart';

/// The items of the selected category, as a grid of tappable cards.
///
/// Every name, description and price comes from the controller's loaded items.
/// Nothing on this screen is hard-coded, so the grid shows exactly what the menu
/// holds.
class MenuItemGrid extends StatelessWidget {
  const MenuItemGrid({super.key});

  /// Target tile width. The grid fits as many whole columns as this allows, so the
  /// same code works on a 13-inch laptop and a wide counter display.
  static const double _targetTileWidth = 232;

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();

    if (controller.isLoadingItems) {
      return const BillingLoadingView(message: 'Loading items');
    }

    if (controller.items.isEmpty) {
      return const BillingEmptyView(
        icon: Icons.no_food_outlined,
        title: 'No items in this category',
        subtitle: 'Nothing is active here yet. Choose another category.',
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _targetTileWidth,
        mainAxisExtent: 132,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: controller.items.length,
      itemBuilder: (BuildContext context, int index) {
        return _MenuItemCard(item: controller.items[index]);
      },
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({required this.item});

  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // The model decides whether the item can be sold; this widget only reads it.
    final bool isSellable = item.isSellable;
    final String? description = item.description;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isSellable
            ? () => context.read<BillingController>().selectItem(item)
            : null,
        child: Opacity(
          opacity: isSellable ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _ItemTypeDot(itemType: item.itemType),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // Expanded, so the description is given exactly the space left over
                // and the price stays on the bottom edge of every tile. The combo
                // descriptions run to a couple of sentences and would otherwise
                // overflow a tile at a narrow column width.
                Expanded(
                  child: description == null
                      ? const SizedBox.shrink()
                      : Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              description,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Text(
                      item.basePrice.formatted,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    if (!isSellable)
                      Text(
                        'Unavailable',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The green or brown dot Indian menus print beside an item.
///
/// Driven by [MenuItem.itemType], not by the item's name.
class _ItemTypeDot extends StatelessWidget {
  const _ItemTypeDot({required this.itemType});

  final MenuItemType itemType;

  @override
  Widget build(BuildContext context) {
    final Color colour = switch (itemType) {
      MenuItemType.veg => const Color(0xFF2E7D32),
      MenuItemType.egg => const Color(0xFFEF6C00),
      MenuItemType.nonVeg => const Color(0xFF8E2F2F),
    };

    return Semantics(
      label: itemType.marker,
      child: Container(
        margin: const EdgeInsets.only(top: 3),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          border: Border.all(color: colour, width: 1.5),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Center(
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
