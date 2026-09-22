import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/menu_category.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_type.dart';
import '../controllers/menu_management_controller.dart';
import 'menu_item_editor.dart';
import 'menu_management_notices.dart';

/// The items tab: every product, grouped by its category, with its price and state.
///
/// Reads [MenuManagementController] only. Deactivated and unavailable items are shown
/// here — this is where their state is changed — even though billing hides the first
/// and blocks the second.
class ItemManagementView extends StatelessWidget {
  const ItemManagementView({super.key});

  @override
  Widget build(BuildContext context) {
    final MenuManagementController controller = context
        .watch<MenuManagementController>();

    return Column(
      children: <Widget>[
        _Header(controller: controller),
        if (controller.hasError)
          MenuErrorBanner(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
            onDismiss: controller.dismissError,
          ),
        Expanded(child: _Body(controller: controller)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final MenuManagementController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canAdd =
        !controller.isSaving && controller.categories.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Items', style: theme.textTheme.titleLarge)),
          FilledButton.icon(
            onPressed: canAdd ? () => _addItem(context, controller) : null,
            icon: const Icon(Icons.add),
            label: const Text('Add item'),
          ),
        ],
      ),
    );
  }
}

Future<void> _addItem(
  BuildContext context,
  MenuManagementController controller, {
  String? categoryId,
}) {
  // Default to the first active category, falling back to the first of any, so the
  // dropdown opens on a sensible choice the owner can change.
  final MenuCategory fallback = controller.categories.firstWhere(
    (MenuCategory c) => c.isActive,
    orElse: () => controller.categories.first,
  );
  return MenuItemEditor.show(
    context,
    controller: controller,
    categoryId: categoryId ?? fallback.id,
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final MenuManagementController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.categories.isEmpty) {
      return const MenuEmptyState(
        icon: Icons.local_pizza_outlined,
        title: 'Add a category first',
        message:
            'Items belong to a category. Create a section on the Categories tab, '
            'then add items to it here.',
      );
    }

    if (controller.items.isEmpty) {
      return MenuEmptyState(
        icon: Icons.local_pizza_outlined,
        title: 'No items yet',
        message:
            'Add the products the outlet sells. Each item belongs to a category '
            'and can have sizes and add-ons.',
        action: FilledButton.icon(
          onPressed: () => _addItem(context, controller),
          icon: const Icon(Icons.add),
          label: const Text('Add the first item'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        for (final MenuCategory category in controller.categories)
          _CategorySection(controller: controller, category: category),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({required this.controller, required this.category});

  final MenuManagementController controller;

  final MenuCategory category;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<MenuItem> items = controller.itemsInCategory(category.id);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: <Widget>[
              Text(
                category.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              if (!category.isActive) ...<Widget>[
                const SizedBox(width: 8),
                const MenuStateChip(label: 'Category inactive'),
              ],
            ],
          ),
        ),
        for (final MenuItem item in items)
          _ItemRow(controller: controller, item: item),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.controller, required this.item});

  final MenuManagementController controller;

  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool busy = controller.isSaving;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: <Widget>[
            _TypeDot(itemType: item.itemType),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          item.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!item.isActive) ...<Widget>[
                        const SizedBox(width: 8),
                        const MenuStateChip(label: 'Inactive'),
                      ],
                      if (item.isActive && !item.isAvailable) ...<Widget>[
                        const SizedBox(width: 8),
                        const MenuStateChip(
                          label: 'Unavailable',
                          tone: MenuChipTone.warning,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.basePrice.formatted,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: item.isActive
                  ? 'Active — on the billing menu'
                  : 'Inactive — hidden from billing',
              child: Switch(
                value: item.isActive,
                onChanged: busy
                    ? null
                    : (bool value) =>
                          controller.setItemActive(item, isActive: value),
              ),
            ),
            IconButton(
              onPressed: busy
                  ? null
                  : () => MenuItemEditor.show(
                      context,
                      controller: controller,
                      categoryId: item.categoryId,
                      item: item,
                    ),
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ${item.name}',
            ),
            PopupMenuButton<_ItemAction>(
              tooltip: 'More actions for ${item.name}',
              enabled: !busy,
              onSelected: (_ItemAction action) => _run(context, action),
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<_ItemAction>>[
                    PopupMenuItem<_ItemAction>(
                      value: _ItemAction.toggleAvailable,
                      child: Text(
                        item.isAvailable
                            ? 'Mark unavailable'
                            : 'Mark available',
                      ),
                    ),
                  ],
            ),
          ],
        ),
      ),
    );
  }

  void _run(BuildContext context, _ItemAction action) {
    switch (action) {
      case _ItemAction.toggleAvailable:
        controller.setItemAvailable(item, isAvailable: !item.isAvailable);
    }
  }
}

enum _ItemAction { toggleAvailable }

class _TypeDot extends StatelessWidget {
  const _TypeDot({required this.itemType});

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
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: colour, width: 1.5),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Center(
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
