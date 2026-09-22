import 'package:flutter/material.dart';

import '../../../../core/money/money.dart';
import '../../domain/models/menu_item_variant.dart';
import '../controllers/menu_management_controller.dart';

/// The form for adding or editing a size.
///
/// A size has a name and an absolute price — the full amount charged for that size,
/// not a difference from the base price. The price is parsed with [Money.parse] into
/// paise and refused if it is not a valid amount, so no `double` and no rounded
/// third decimal ever reaches the controller.
class MenuVariantEditor extends StatefulWidget {
  const MenuVariantEditor({
    required this.controller,
    required this.menuItemId,
    this.variant,
    super.key,
  });

  /// Opens the form. Returns true when something was saved.
  static Future<bool> show(
    BuildContext context, {
    required MenuManagementController controller,
    required String menuItemId,
    MenuItemVariant? variant,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => MenuVariantEditor(
        controller: controller,
        menuItemId: menuItemId,
        variant: variant,
      ),
    );
    return saved ?? false;
  }

  final MenuManagementController controller;

  final String menuItemId;

  /// The size being edited, or `null` when adding one.
  final MenuItemVariant? variant;

  @override
  State<MenuVariantEditor> createState() => _MenuVariantEditorState();
}

class _MenuVariantEditorState extends State<MenuVariantEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.variant?.name ?? '',
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.variant?.price.toDecimalString() ?? '',
  );

  String? _validation;

  bool get _isNew => widget.variant == null;

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
      title: Text(_isNew ? 'Add size' : 'Edit size'),
      content: SizedBox(
        width: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Size name',
                helperText: 'For example Small, Medium, Large',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Price (₹)',
                helperText: 'The full price charged for this size',
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_validation != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                _validation!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_validation == null && repositoryError != null) ...<Widget>[
              const SizedBox(height: 16),
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
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.controller.isSaving ? null : _save,
          child: Text(_isNew ? 'Add size' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _validation = 'Give the size a name.');
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

    final MenuItemVariant? existing = widget.variant;
    final bool saved = existing == null
        ? await widget.controller.createVariant(
            menuItemId: widget.menuItemId,
            name: name,
            price: price,
          )
        : await widget.controller.updateVariant(
            existing,
            name: name,
            price: price,
          );

    if (saved && mounted) {
      Navigator.of(context).pop(true);
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
