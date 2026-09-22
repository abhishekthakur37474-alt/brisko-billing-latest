import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/models/menu_category.dart';
import '../controllers/menu_management_controller.dart';
import 'menu_category_editor.dart';
import 'menu_management_notices.dart';

/// The categories tab: every section, its order, and whether it is active.
///
/// Reads [MenuManagementController] and nothing else. A row on screen is a row that was
/// stored; there is no SQL and no sample data here.
class CategoryManagementView extends StatelessWidget {
  const CategoryManagementView({super.key});

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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text('Categories', style: theme.textTheme.titleLarge),
          ),
          FilledButton.icon(
            onPressed: controller.isSaving
                ? null
                : () =>
                      MenuCategoryEditor.show(context, controller: controller),
            icon: const Icon(Icons.add),
            label: const Text('Add category'),
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

    if (controller.categories.isEmpty) {
      return MenuEmptyState(
        icon: Icons.category_outlined,
        title: 'No categories yet',
        message:
            'Add the sections the menu is organised into, such as Veg Pizza or '
            'Cold Drinks. Items are added to a category.',
        action: FilledButton.icon(
          onPressed: () =>
              MenuCategoryEditor.show(context, controller: controller),
          icon: const Icon(Icons.add),
          label: const Text('Add the first category'),
        ),
      );
    }

    final List<MenuCategory> categories = controller.categories;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: categories.length,
      itemBuilder: (BuildContext context, int index) {
        return _CategoryRow(
          controller: controller,
          category: categories[index],
          isFirst: index == 0,
          isLast: index == categories.length - 1,
        );
      },
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.controller,
    required this.category,
    required this.isFirst,
    required this.isLast,
  });

  final MenuManagementController controller;

  final MenuCategory category;

  final bool isFirst;

  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int itemCount = controller.itemsInCategory(category.id).length;
    final bool busy = controller.isSaving;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Column(
              children: <Widget>[
                IconButton(
                  onPressed: busy || isFirst
                      ? null
                      : () => controller.moveCategoryUp(category),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: 'Move up',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: busy || isLast
                      ? null
                      : () => controller.moveCategoryDown(category),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: 'Move down',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          category.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!category.isActive) ...<Widget>[
                        const SizedBox(width: 8),
                        const MenuStateChip(label: 'Inactive'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    itemCount == 1 ? '1 item' : '$itemCount items',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: category.isActive
                  ? 'Active — shown at the counter'
                  : 'Inactive — hidden from billing',
              child: Switch(
                value: category.isActive,
                onChanged: busy
                    ? null
                    : (bool value) => controller.setCategoryActive(
                        category,
                        isActive: value,
                      ),
              ),
            ),
            IconButton(
              onPressed: busy
                  ? null
                  : () => MenuCategoryEditor.show(
                      context,
                      controller: controller,
                      category: category,
                    ),
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Rename ${category.name}',
            ),
          ],
        ),
      ),
    );
  }
}
