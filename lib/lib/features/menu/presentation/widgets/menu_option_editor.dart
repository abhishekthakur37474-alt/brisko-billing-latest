import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../domain/models/menu_category.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_option.dart';
import '../../domain/models/menu_item_variant.dart';
import '../../domain/models/menu_option_scope.dart';
import '../../domain/models/menu_option_type.dart';
import '../controllers/menu_management_controller.dart';

/// The form for adding or editing an option (a crust, an add-on or a condiment).
///
/// ## Scope is chosen on create, fixed on edit
///
/// A new option is given a scope — all items, a category, an item, or one size of an
/// item — which is stored as the id columns the existing option system uses. Nothing
/// here redesigns that system, and the four-level resolution (variant → item →
/// category → global) is untouched.
///
/// When editing, the scope is shown but cannot be changed. Broadening a size-specific
/// price to every product because a name was corrected is exactly the accident this
/// prevents; to move an option, deactivate it and add a new one at the intended scope.
class MenuOptionEditor extends StatefulWidget {
  const MenuOptionEditor({required this.controller, this.option, super.key});

  /// Opens the form. Returns true when something was saved.
  static Future<bool> show(
    BuildContext context, {
    required MenuManagementController controller,
    MenuItemOption? option,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) =>
          MenuOptionEditor(controller: controller, option: option),
    );
    return saved ?? false;
  }

  final MenuManagementController controller;

  /// The option being edited, or `null` when adding one.
  final MenuItemOption? option;

  @override
  State<MenuOptionEditor> createState() => _MenuOptionEditorState();
}

class _MenuOptionEditorState extends State<MenuOptionEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.option?.name ?? '',
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.option?.price.toDecimalString() ?? '',
  );

  late MenuOptionType _optionType =
      widget.option?.optionType ?? MenuOptionType.addOn;

  // Scope draft, used only when creating.
  MenuOptionScope _scope = MenuOptionScope.global;
  String? _categoryId;
  String? _itemId;
  String? _variantId;
  List<MenuItemVariant> _itemVariants = const <MenuItemVariant>[];
  bool _loadingVariants = false;

  String? _validation;

  bool get _isNew => widget.option == null;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? repositoryError = widget.controller.errorMessage;

    return AlertDialog(
      title: Text(_isNew ? 'Add option' : 'Edit option'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'The customisation, with no size in it',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<MenuOptionType>(
                initialValue: _optionType,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: <DropdownMenuItem<MenuOptionType>>[
                  for (final MenuOptionType type in MenuOptionType.values)
                    DropdownMenuItem<MenuOptionType>(
                      value: type,
                      child: Text(type.label),
                    ),
                ],
                onChanged: (MenuOptionType? chosen) {
                  if (chosen != null) {
                    setState(() => _optionType = chosen);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Price (₹)',
                  helperText: 'What it adds to the line. Zero is allowed.',
                ),
              ),
              const SizedBox(height: 16),
              if (_isNew) _scopeSection(theme) else _scopeSummary(theme),
              if (_validation != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _validation!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (_validation == null && repositoryError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  repositoryError,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.controller.isSaving ? null : _save,
          child: Text(_isNew ? 'Add option' : 'Save'),
        ),
      ],
    );
  }

  /// The scope chooser shown when creating an option.
  Widget _scopeSection(ThemeData theme) {
    final List<MenuCategory> categories = widget.controller.categories;
    final List<MenuItem> items = widget.controller.items;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<MenuOptionScope>(
          initialValue: _scope,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Applies to'),
          items: <DropdownMenuItem<MenuOptionScope>>[
            for (final MenuOptionScope scope in MenuOptionScope.values)
              DropdownMenuItem<MenuOptionScope>(
                value: scope,
                child: Text(scope.label),
              ),
          ],
          onChanged: (MenuOptionScope? chosen) {
            if (chosen != null) {
              setState(() {
                _scope = chosen;
                _categoryId = null;
                _itemId = null;
                _variantId = null;
                _itemVariants = const <MenuItemVariant>[];
              });
            }
          },
        ),
        if (_scope == MenuOptionScope.category) ...<Widget>[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category'),
            items: <DropdownMenuItem<String>>[
              for (final MenuCategory category in categories)
                DropdownMenuItem<String>(
                  value: category.id,
                  child: Text(category.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (String? chosen) => setState(() => _categoryId = chosen),
          ),
        ],
        if (_scope == MenuOptionScope.item ||
            _scope == MenuOptionScope.variant) ...<Widget>[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _itemId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Item'),
            items: <DropdownMenuItem<String>>[
              for (final MenuItem item in items)
                DropdownMenuItem<String>(
                  value: item.id,
                  child: Text(item.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _onItemChosen,
          ),
        ],
        if (_scope == MenuOptionScope.variant) ...<Widget>[
          const SizedBox(height: 16),
          if (_loadingVariants)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          else if (_itemId != null && _itemVariants.isEmpty)
            Text(
              'That item has no sizes. Add sizes on the Variants tab, or scope '
              'this option to the item instead.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _variantId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Size'),
              items: <DropdownMenuItem<String>>[
                for (final MenuItemVariant variant in _itemVariants)
                  DropdownMenuItem<String>(
                    value: variant.id,
                    child: Text(variant.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (String? chosen) =>
                  setState(() => _variantId = chosen),
            ),
        ],
      ],
    );
  }

  /// The read-only scope shown when editing.
  Widget _scopeSummary(ThemeData theme) {
    final MenuItemOption option = widget.option!;
    final String detail = switch (option.scope) {
      MenuOptionScope.global => 'All items',
      MenuOptionScope.category =>
        'Category: ${widget.controller.categoryName(option.categoryId!)}',
      MenuOptionScope.item =>
        'Item: ${widget.controller.itemById(option.menuItemId!)?.name ?? 'Unknown item'}',
      MenuOptionScope.variant => 'One size of an item',
    };

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Applies to',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: Text(detail),
    );
  }

  Future<void> _onItemChosen(String? itemId) async {
    setState(() {
      _itemId = itemId;
      _variantId = null;
      _itemVariants = const <MenuItemVariant>[];
      _loadingVariants = _scope == MenuOptionScope.variant && itemId != null;
    });

    if (_scope != MenuOptionScope.variant || itemId == null) {
      return;
    }

    final List<MenuItemVariant> variants = await widget.controller.variantsOf(
      itemId,
    );
    if (!mounted || _itemId != itemId) {
      return;
    }
    setState(() {
      _itemVariants = variants;
      _loadingVariants = false;
    });
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _validation = 'Give the option a name.');
      return;
    }

    final Money? price = _parsePrice(_price.text);
    if (price == null) {
      setState(
        () => _validation =
            'Enter the price as an amount, up to two decimal places. Use 0 for '
            'a free option.',
      );
      return;
    }
    if (price.isNegative) {
      setState(() => _validation = 'A price cannot be negative.');
      return;
    }

    final MenuItemOption? existing = widget.option;
    if (existing != null) {
      setState(() => _validation = null);
      final bool updated = await widget.controller.updateOption(
        existing,
        name: name,
        optionType: _optionType,
        price: price,
      );
      if (updated && mounted) {
        Navigator.of(context).pop(true);
      }
      return;
    }

    final String? scopeError = _scopeValidation();
    if (scopeError != null) {
      setState(() => _validation = scopeError);
      return;
    }
    setState(() => _validation = null);

    final bool created = await widget.controller.createOption(
      name: name,
      optionType: _optionType,
      price: price,
      categoryId: _scope == MenuOptionScope.category ? _categoryId : null,
      menuItemId: _scope == MenuOptionScope.item ? _itemId : null,
      variantId: _scope == MenuOptionScope.variant ? _variantId : null,
    );

    if (created && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// Why the chosen scope is incomplete, or `null`.
  String? _scopeValidation() {
    switch (_scope) {
      case MenuOptionScope.global:
        return null;
      case MenuOptionScope.category:
        return _categoryId == null ? 'Choose a category.' : null;
      case MenuOptionScope.item:
        return _itemId == null ? 'Choose an item.' : null;
      case MenuOptionScope.variant:
        if (_itemId == null) {
          return 'Choose an item.';
        }
        return _variantId == null ? 'Choose a size.' : null;
    }
  }

  static Money? _parsePrice(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      return Money.parse(trimmed);
    } on FormatException {
      return null;
    }
  }
}
