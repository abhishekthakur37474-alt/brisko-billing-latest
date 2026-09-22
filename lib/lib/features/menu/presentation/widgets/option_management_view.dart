import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/menu_item_option.dart';
import '../../domain/models/menu_option_scope.dart';
import '../controllers/menu_management_controller.dart';
import 'menu_management_notices.dart';
import 'menu_option_editor.dart';

/// The options tab: every crust, add-on and condiment, its price, scope and state.
///
/// The scope is shown on every row so the owner can see at a glance whether an option
/// applies to everything or only to one item or size. A size-specific price is shown as
/// itself rather than collapsed, because this is maintenance, not the counter.
class OptionManagementView extends StatelessWidget {
  const OptionManagementView({super.key});

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
            child: Text('Options & add-ons', style: theme.textTheme.titleLarge),
          ),
          FilledButton.icon(
            onPressed: controller.isSaving
                ? null
                : () => MenuOptionEditor.show(context, controller: controller),
            icon: const Icon(Icons.add),
            label: const Text('Add option'),
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

    final List<MenuItemOption> options = controller.options;
    if (options.isEmpty) {
      return MenuEmptyState(
        icon: Icons.tune,
        title: 'No options yet',
        message:
            'Add crusts, add-ons and condiments. An option can apply to every '
            'item, one category, one item, or one size.',
        action: FilledButton.icon(
          onPressed: () =>
              MenuOptionEditor.show(context, controller: controller),
          icon: const Icon(Icons.add),
          label: const Text('Add the first option'),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: options.length,
      itemBuilder: (BuildContext context, int index) {
        return _OptionRow(controller: controller, option: options[index]);
      },
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.controller, required this.option});

  final MenuManagementController controller;

  final MenuItemOption option;

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
                          option.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!option.isActive) ...<Widget>[
                        const SizedBox(width: 8),
                        const MenuStateChip(label: 'Inactive'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      MenuStateChip(label: option.optionType.label),
                      MenuStateChip(label: _scopeLabel),
                      Text(
                        option.price.formattedAsAddition,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Tooltip(
              message: option.isActive
                  ? 'Active — offered at the counter'
                  : 'Inactive — not offered',
              child: Switch(
                value: option.isActive,
                onChanged: busy
                    ? null
                    : (bool value) =>
                          controller.setOptionActive(option, isActive: value),
              ),
            ),
            IconButton(
              onPressed: busy
                  ? null
                  : () => MenuOptionEditor.show(
                      context,
                      controller: controller,
                      option: option,
                    ),
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ${option.name}',
            ),
          ],
        ),
      ),
    );
  }

  /// A readable scope, naming the target where one is known.
  String get _scopeLabel {
    switch (option.scope) {
      case MenuOptionScope.global:
        return 'All items';
      case MenuOptionScope.category:
        return controller.categoryName(option.categoryId!);
      case MenuOptionScope.item:
        return controller.itemById(option.menuItemId!)?.name ?? 'One item';
      case MenuOptionScope.variant:
        return 'One size';
    }
  }
}
