import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../domain/models/menu_category.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_type.dart';
import '../controllers/menu_management_controller.dart';

/// The form for creating or editing a menu item.
///
/// ## What "price" means here
///
/// The base price is what the item costs when it is sold without a size. A pizza that
/// is priced by size takes its actual price from the chosen size, added on the
/// Variants tab; the base price is then the fallback and the smallest-size default.
/// This is stated on the form rather than left to be discovered.
///
/// ## Prices are parsed once, into paise
///
/// The amount is read from the field with [Money.parse] and refused if it is not a
/// valid amount, so nothing but an exact integer number of paise ever reaches the
/// controller. There is no `double` here.
class MenuItemEditor extends StatefulWidget {
  const MenuItemEditor({
    required this.controller,
    required this.categoryId,
    this.item,
    super.key,
  });

  /// Opens the form. Returns true when something was saved.
  ///
  /// [categoryId] is the category a new item starts in, and the one preselected in the
  /// dropdown. When [item] is supplied the item's own category wins.
  static Future<bool> show(
    BuildContext context, {
    required MenuManagementController controller,
    required String categoryId,
    MenuItem? item,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => MenuItemEditor(
        controller: controller,
        categoryId: categoryId,
        item: item,
      ),
    );
    return saved ?? false;
  }

  final MenuManagementController controller;

  final String categoryId;

  /// The item being edited, or `null` when creating one.
  final MenuItem? item;

  @override
  State<MenuItemEditor> createState() => _MenuItemEditorState();
}

class _MenuItemEditorState extends State<MenuItemEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.item?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.item?.description ?? '',
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.item?.basePrice.toDecimalString() ?? '',
  );

  late String _categoryId = widget.item?.categoryId ?? widget.categoryId;
  late MenuItemType _itemType = widget.item?.itemType ?? MenuItemType.veg;
  late bool _isAvailable = widget.item?.isAvailable ?? true;

  String? _validation;

  bool get _isNew => widget.item == null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? repositoryError = widget.controller.errorMessage;
    final List<MenuCategory> categories = widget.controller.categories;

    return AlertDialog(
      title: Text(_isNew ? 'Add item' : 'Edit item'),
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
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue:
                    categories.any((MenuCategory c) => c.id == _categoryId)
                    ? _categoryId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: <DropdownMenuItem<String>>[
                  for (final MenuCategory category in categories)
                    DropdownMenuItem<String>(
                      value: category.id,
                      child: Text(
                        category.isActive
                            ? category.name
                            : '${category.name} (inactive)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? chosen) {
                  if (chosen != null) {
                    setState(() => _categoryId = chosen);
                  }
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<MenuItemType>(
                initialValue: _itemType,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Food type'),
                items: <DropdownMenuItem<MenuItemType>>[
                  for (final MenuItemType type in MenuItemType.values)
                    DropdownMenuItem<MenuItemType>(
                      value: type,
                      child: Text(type.marker),
                    ),
                ],
                onChanged: (MenuItemType? chosen) {
                  if (chosen != null) {
                    setState(() => _itemType = chosen);
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
                  labelText: 'Base price (₹)',
                  helperText:
                      'The price without a size. For a size-priced item, add the '
                      'sizes on the Variants tab.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isAvailable,
                onChanged: (bool value) => setState(() => _isAvailable = value),
                title: const Text('Available'),
                subtitle: Text(
                  _isAvailable
                      ? 'Can be added to a bill'
                      : 'Shown on the menu but cannot be sold right now',
                  style: theme.textTheme.bodySmall,
                ),
              ),
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
          child: Text(_isNew ? 'Add item' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _validation = 'Give the item a name.');
      return;
    }

    final Money? price = _parsePrice(_price.text);
    if (price == null) {
      setState(
        () => _validation =
            'Enter the price as an amount, up to two decimal places.',
      );
      return;
    }
    if (price.isNegative) {
      setState(() => _validation = 'A price cannot be negative.');
      return;
    }

    setState(() => _validation = null);

    final MenuItem? existing = widget.item;
    final bool saved = existing == null
        ? await widget.controller.createItem(
            categoryId: _categoryId,
            name: name,
            basePrice: price,
            itemType: _itemType,
            description: _description.text,
            isAvailable: _isAvailable,
          )
        : await _saveEdit(existing, name, price);

    if (saved && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// Saves an edit, including a change to availability that the base editor toggle
  /// carries but [MenuManagementController.updateItem] does not.
  Future<bool> _saveEdit(MenuItem existing, String name, Money price) async {
    final bool updated = await widget.controller.updateItem(
      existing,
      name: name,
      basePrice: price,
      itemType: _itemType,
      categoryId: _categoryId,
      description: _description.text,
    );
    if (!updated) {
      return false;
    }
    if (existing.isAvailable != _isAvailable) {
      // Re-read the item so the availability write is applied to the freshly saved
      // row rather than the stale one held by this dialog.
      final MenuItem refreshed =
          widget.controller.itemById(existing.id) ?? existing;
      return widget.controller.setItemAvailable(
        refreshed,
        isAvailable: _isAvailable,
      );
    }
    return true;
  }

  /// [text] as an amount, or `null` when it is not one.
  ///
  /// [Money.parse] throws on anything that is not a valid amount, including more than
  /// two decimal places, which is exactly the data-entry mistake that must be refused
  /// rather than silently rounded.
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
