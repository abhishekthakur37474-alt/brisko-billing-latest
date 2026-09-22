import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../menu/domain/models/menu_category.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_variant.dart';
import '../../domain/models/inventory_item.dart';
import '../../domain/models/recipe_ingredient.dart';
import '../controllers/recipe_controller.dart';
import 'inventory_notices.dart';
import 'recipe_ingredient_editor.dart';

/// What each dish consumes: pick a dish, pick a size if it has them, list the
/// ingredients.
///
/// ## Layout
///
/// Two columns on a till or desktop — the menu on the left, the chosen dish's recipe on
/// the right — and one stacked column on a narrow window. The menu stays visible on a
/// wide screen because configuring recipes is repetitive work down a list, and having to
/// navigate back after every dish would double the taps.
class RecipeView extends StatelessWidget {
  const RecipeView({super.key});

  @override
  Widget build(BuildContext context) {
    final RecipeController controller = context.watch<RecipeController>();
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: <Widget>[
        if (controller.hasError)
          InventoryErrorBanner(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
            onDismiss: controller.dismissError,
          ),
        if (controller.hasNoStockItems) const _NoStockItemsNotice(),
        Expanded(
          child: controller.hasNoMenu
              ? const InventoryEmptyState(
                  icon: Icons.menu_book_outlined,
                  title: 'No menu to configure',
                  message:
                      'Recipes are written against the menu. There are no menu '
                      'items to configure yet.',
                )
              : isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: 320,
                      child: _MenuPicker(controller: controller),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _RecipePanel(controller: controller)),
                  ],
                )
              : ListView(
                  children: <Widget>[
                    _MenuPicker(controller: controller, shrinkWrap: true),
                    const Divider(),
                    _RecipePanel(controller: controller, shrinkWrap: true),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Says plainly that nothing can be configured yet, and where to go first.
///
/// Shown rather than offering an empty ingredient picker, which would look broken.
class _NoStockItemsNotice extends StatelessWidget {
  const _NoStockItemsNotice();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.info_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No stock items yet. Add them under Stock first, then come back '
              'to say how much of each a dish uses.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Category, then dish.
class _MenuPicker extends StatelessWidget {
  const _MenuPicker({required this.controller, this.shrinkWrap = false});

  final RecipeController controller;

  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: DropdownButtonFormField<MenuCategory>(
            initialValue: controller.selectedCategory,
            // Expanded and ellipsised, because the real menu has category names such
            // as "Twin Treat Pizza Combo" that are wider than the picker.
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category'),
            items: <DropdownMenuItem<MenuCategory>>[
              for (final MenuCategory category in controller.categories)
                DropdownMenuItem<MenuCategory>(
                  value: category,
                  child: Text(category.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (MenuCategory? category) {
              if (category != null) {
                controller.selectCategory(category);
              }
            },
          ),
        ),
        if (controller.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No items in this category.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: shrinkWrap,
              physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
              padding: const EdgeInsets.only(bottom: 16),
              children: <Widget>[
                for (final MenuItem item in controller.items)
                  ListTile(
                    title: Text(item.name),
                    selected: controller.selectedItem?.id == item.id,
                    // States whether the dish will deduct anything when it is sold.
                    // The whole point of the screen is to make that visible without
                    // opening every item.
                    subtitle: Text(
                      controller.isConfigured(item.id)
                          ? 'Recipe configured'
                          : 'No recipe',
                    ),
                    trailing: Icon(
                      controller.isConfigured(item.id)
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => controller.selectItem(item),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The chosen dish's ingredients.
class _RecipePanel extends StatelessWidget {
  const _RecipePanel({required this.controller, this.shrinkWrap = false});

  final RecipeController controller;

  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final MenuItem? item = controller.selectedItem;

    if (item == null) {
      return const InventoryEmptyState(
        icon: Icons.touch_app_outlined,
        title: 'Choose an item',
        message: 'Pick a menu item to see and edit what it uses.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RecipeHeader(controller: controller, item: item),
        if (controller.hasVariants) _VariantPicker(controller: controller),
        Flexible(
          child: _IngredientList(
            controller: controller,
            shrinkWrap: shrinkWrap,
          ),
        ),
      ],
    );
  }
}

class _RecipeHeader extends StatelessWidget {
  const _RecipeHeader({required this.controller, required this.item});

  final RecipeController controller;

  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MenuItemVariant? variant = controller.selectedVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.name, style: theme.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(
                  variant == null
                      ? controller.hasVariants
                            // Worth spelling out: this recipe is not "the Small one",
                            // it is the one every size falls back to.
                            ? 'Recipe for all sizes'
                            : 'Recipe for this item'
                      : 'Recipe for ${variant.name}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            // Disabled with a reason rather than silently: the outlet has no stock
            // items, or every one of them is already on this recipe.
            onPressed: controller.availableStockItems.isEmpty
                ? null
                : () => RecipeIngredientEditor.add(
                    context,
                    controller: controller,
                  ),
            icon: const Icon(Icons.add),
            label: const Text('Add ingredient'),
          ),
        ],
      ),
    );
  }
}

/// Which recipe of a sized dish is being edited: the shared one, or one size's own.
class _VariantPicker extends StatelessWidget {
  const _VariantPicker({required this.controller});

  final RecipeController controller;

  @override
  Widget build(BuildContext context) {
    final MenuItemVariant? selected = controller.selectedVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          ChoiceChip(
            label: const Text('All sizes'),
            selected: selected == null,
            onSelected: (bool chosen) {
              if (chosen) {
                controller.selectVariant(null);
              }
            },
          ),
          for (final MenuItemVariant variant in controller.variants)
            ChoiceChip(
              label: Text(variant.name),
              selected: selected?.id == variant.id,
              onSelected: (bool chosen) {
                if (chosen) {
                  controller.selectVariant(variant);
                }
              },
            ),
        ],
      ),
    );
  }
}

class _IngredientList extends StatelessWidget {
  const _IngredientList({required this.controller, this.shrinkWrap = false});

  final RecipeController controller;

  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    if (controller.recipe == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.isUnconfigured) {
      return InventoryEmptyState(
        icon: Icons.no_food_outlined,
        title: 'No ingredients configured for this item.',
        message: controller.selectedVariant == null && controller.hasVariants
            ? 'Nothing is deducted when it is sold. Add ingredients here to '
                  'cover every size, or pick a size to give it its own recipe.'
            : 'Nothing is deducted when it is sold.',
      );
    }

    final List<RecipeIngredient> ingredients = controller.ingredients;

    return ListView.separated(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: ingredients.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) => _IngredientRow(
        controller: controller,
        ingredient: ingredients[index],
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.controller, required this.ingredient});

  final RecipeController controller;

  final RecipeIngredient ingredient;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final InventoryItem? stock = controller.stockItemFor(ingredient);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    // A deleted stock item cannot normally be on a live recipe, since
                    // deletion is refused while one uses it. Named rather than
                    // rendered blank in case the list on screen is a moment behind.
                    stock?.name ?? 'Stock item no longer available',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (stock != null)
                    Text(
                      'In stock: ${stock.currentQuantityWithUnit}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              stock == null
                  ? ingredient.quantityDisplay
                  : stock.unit.describe(ingredient.quantityDisplay),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(width: 4),
            Text(
              'per unit',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Edit quantity',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => RecipeIngredientEditor.edit(
                context,
                controller: controller,
                ingredient: ingredient,
              ),
            ),
            IconButton(
              tooltip: 'Remove ingredient',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => controller.removeIngredient(ingredient),
            ),
          ],
        ),
      ),
    );
  }
}
