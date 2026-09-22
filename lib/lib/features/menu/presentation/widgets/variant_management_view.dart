import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_variant.dart';
import '../controllers/menu_management_controller.dart';
import 'menu_management_notices.dart';
import 'menu_variant_editor.dart';

/// The sizes tab: choose an item, then manage the sizes it is sold in.
///
/// Not every item has sizes. An item with none is sold at its base price, which is the
/// truthful thing this tab says when it is opened on such an item.
class VariantManagementView extends StatelessWidget {
  const VariantManagementView({super.key});

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
    final List<MenuItem> items = controller.items;
    final String? selected = controller.variantItemId;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Text('Sizes for', style: theme.textTheme.titleMedium),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: items.any((MenuItem i) => i.id == selected)
                  ? selected
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'Choose an item',
              ),
              items: <DropdownMenuItem<String>>[
                for (final MenuItem item in items)
                  DropdownMenuItem<String>(
                    value: item.id,
                    child: Text(
                      item.isActive ? item.name : '${item.name} (inactive)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: controller.isLoading
                  ? null
                  : (String? chosen) {
                      if (chosen != null) {
                        controller.selectVariantItem(chosen);
                      }
                    },
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: selected == null || controller.isSaving
                ? null
                : () => MenuVariantEditor.show(
                    context,
                    controller: controller,
                    menuItemId: selected,
                  ),
            icon: const Icon(Icons.add),
            label: const Text('Add size'),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final MenuManagementController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? selected = controller.variantItemId;
    if (selected == null) {
      return const MenuEmptyState(
        icon: Icons.straighten_outlined,
        title: 'Choose an item',
        message:
            'Pick an item above to manage its sizes. An item can have no sizes, '
            'one, or several.',
      );
    }

    if (controller.isLoadingVariants) {
      return const Center(child: CircularProgressIndicator());
    }

    final MenuItem? item = controller.itemById(selected);
    final List<MenuItemVariant> variants = controller.variants;

    if (variants.isEmpty) {
      return MenuEmptyState(
        icon: Icons.straighten_outlined,
        title: 'No sizes',
        message:
            '${item?.name ?? 'This item'} is sold at its base price of '
            '${item?.basePrice.formatted ?? '—'}. Add a size to price it by '
            'size instead.',
        action: FilledButton.icon(
          onPressed: () => MenuVariantEditor.show(
            context,
            controller: controller,
            menuItemId: selected,
          ),
          icon: const Icon(Icons.add),
          label: const Text('Add the first size'),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: variants.length,
      itemBuilder: (BuildContext context, int index) {
        return _VariantRow(
          controller: controller,
          menuItemId: selected,
          variant: variants[index],
        );
      },
    );
  }
}

class _VariantRow extends StatelessWidget {
  const _VariantRow({
    required this.controller,
    required this.menuItemId,
    required this.variant,
  });

  final MenuManagementController controller;

  final String menuItemId;

  final MenuItemVariant variant;

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          variant.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!variant.isActive) ...<Widget>[
                        const SizedBox(width: 8),
                        const MenuStateChip(label: 'Inactive'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    variant.price.formatted,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: variant.isActive
                  ? 'Active — can be chosen'
                  : 'Inactive — cannot be chosen',
              child: Switch(
                value: variant.isActive,
                onChanged: busy
                    ? null
                    : (bool value) =>
                          controller.setVariantActive(variant, isActive: value),
              ),
            ),
            IconButton(
              onPressed: busy
                  ? null
                  : () => MenuVariantEditor.show(
                      context,
                      controller: controller,
                      menuItemId: menuItemId,
                      variant: variant,
                    ),
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ${variant.name}',
            ),
          ],
        ),
      ),
    );
  }
}
