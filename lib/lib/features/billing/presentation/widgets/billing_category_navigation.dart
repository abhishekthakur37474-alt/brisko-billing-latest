import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../menu/domain/models/menu_category.dart';
import '../controllers/billing_controller.dart';

/// Category list for the wide layout, down the left edge of the billing screen.
///
/// Renders whatever categories the controller loaded, in the order it loaded them.
/// It has no list of its own, so a category added to the menu appears here without a
/// code change.
class BillingCategoryRail extends StatelessWidget {
  const BillingCategoryRail({super.key});

  /// Wide enough for the longest seeded category name at the counter's font size.
  static const double width = 208;

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final ThemeData theme = Theme.of(context);
    final String? selectedId = controller.selectedCategory?.id;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Categories',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: controller.categories.length,
              itemBuilder: (BuildContext context, int index) {
                final MenuCategory category = controller.categories[index];
                return _CategoryTile(
                  category: category,
                  isSelected: category.id == selectedId,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.isSelected});

  final MenuCategory category;

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        title: Text(category.name),
        selected: isSelected,
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: () => context.read<BillingController>().selectCategory(category),
      ),
    );
  }
}

/// Category selector for narrow layouts, as a single scrolling row of chips.
class BillingCategoryStrip extends StatelessWidget {
  const BillingCategoryStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final String? selectedId = controller.selectedCategory?.id;

    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: controller.categories.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final MenuCategory category = controller.categories[index];
          return ChoiceChip(
            label: Text(category.name),
            selected: category.id == selectedId,
            onSelected: (bool _) =>
                context.read<BillingController>().selectCategory(category),
          );
        },
      ),
    );
  }
}
