import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money.dart';
import '../../../../core/money/money_display.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_option.dart';
import '../../../menu/domain/models/menu_item_variant.dart';
import '../../../menu/domain/models/menu_option_type.dart';
import '../controllers/billing_controller.dart';

/// Size and customisation selection for the item being configured.
///
/// ## What this widget does not know
///
/// It does not know why an option is offered. It renders
/// [BillingController.availableOptions], which the repository resolved for the exact
/// selection, already priced and already ordered. There is no scope here, no
/// `variantId`, no size parsed out of a name, and no price computed in this file: a
/// Large pizza shows no crust upgrade simply because the repository returned none.
///
/// Whether a tap selects or replaces is also not decided here. The widget reports the
/// tap to [BillingController.toggleOption] and re-renders the result.
class ItemConfigurationPanel extends StatelessWidget {
  const ItemConfigurationPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final BillingController controller = context.watch<BillingController>();
    final MenuItem? item = controller.configuringItem;

    if (item == null) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PanelHeader(item: item),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: <Widget>[
              if (controller.requiresVariantSelection) ...<Widget>[
                _SectionHeading(
                  title: 'Size',
                  hint: controller.selectedVariant == null
                      ? 'Required'
                      : 'One per item',
                ),
                const SizedBox(height: 8),
                _VariantChoices(controller: controller),
                const SizedBox(height: 24),
              ],
              _CustomisationSection(controller: controller),
            ],
          ),
        ),
        const Divider(height: 1),
        _PanelFooter(controller: controller, theme: theme),
      ],
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.item});

  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? description = item.description;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: context.read<BillingController>().cancelConfiguration,
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to the menu',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(item.name, style: theme.textTheme.titleMedium),
                if (description != null)
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VariantChoices extends StatelessWidget {
  const _VariantChoices({required this.controller});

  final BillingController controller;

  @override
  Widget build(BuildContext context) {
    final String? selectedId = controller.selectedVariant?.id;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final MenuItemVariant variant in controller.variants)
          ChoiceChip(
            selected: variant.id == selectedId,
            onSelected: (bool _) =>
                context.read<BillingController>().selectVariant(variant),
            label: Text('${variant.name}  ${variant.price.formatted}'),
          ),
      ],
    );
  }
}

/// The options section, including its own loading, waiting and empty states.
class _CustomisationSection extends StatelessWidget {
  const _CustomisationSection({required this.controller});

  final BillingController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (controller.isLoadingOptions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    if (controller.requiresVariantSelection &&
        controller.selectedVariant == null) {
      return _Note(
        'Choose a size to see the customisations and their prices.',
        theme: theme,
      );
    }

    if (controller.availableOptions.isEmpty) {
      return _Note('No customisations are offered here.', theme: theme);
    }

    final Map<MenuOptionType, List<MenuItemOption>> groups =
        controller.optionGroups;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Iterating the enum rather than the map keys keeps the section order fixed
        // even when a group happens to be empty for this selection.
        for (final MenuOptionType type in MenuOptionType.values)
          if (groups[type] != null) ...<Widget>[
            _SectionHeading(title: _title(type), hint: _hint(type)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final MenuItemOption option in groups[type]!)
                  FilterChip(
                    selected: controller.isOptionSelected(option.id),
                    onSelected: (bool _) =>
                        context.read<BillingController>().toggleOption(option),
                    label: Text(
                      '${option.name}  ${option.price.formattedAsAddition}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
      ],
    );
  }

  /// Display text only. How a selection behaves is decided by the controller.
  static String _title(MenuOptionType type) => switch (type) {
    MenuOptionType.crust => 'Choice of crust',
    MenuOptionType.addOn => 'Add-ons',
    MenuOptionType.condiment => 'Condiments',
  };

  static String _hint(MenuOptionType type) => switch (type) {
    MenuOptionType.crust => 'One per item',
    MenuOptionType.addOn => 'Optional',
    MenuOptionType.condiment => 'Optional',
  };
}

class _PanelFooter extends StatelessWidget {
  const _PanelFooter({required this.controller, required this.theme});

  final BillingController controller;

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final Money? unitPrice = controller.draftUnitPrice;
    final Money? basePrice = controller.draftBasePrice;
    final Money optionsTotal = controller.draftOptionsTotal;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  unitPrice == null ? '—' : unitPrice.formatted,
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  basePrice == null
                      ? 'Choose a size to price this item'
                      : optionsTotal.isZero
                      ? 'Base ${basePrice.formatted}'
                      : 'Base ${basePrice.formatted} '
                            '+ options ${optionsTotal.formatted}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            // Disabled until the draft is complete. The controller decides.
            onPressed: controller.canAddToCart
                ? context.read<BillingController>().addConfiguredItemToCart
                : null,
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('Add to bill'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.hint});

  final String title;

  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(width: 8),
        Text(
          hint,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.message, {required this.theme});

  final String message;

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
