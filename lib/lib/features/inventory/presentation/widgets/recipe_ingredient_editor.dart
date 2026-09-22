import 'package:flutter/material.dart';

import '../../domain/models/inventory_item.dart';
import '../../domain/models/recipe_ingredient.dart';
import '../../domain/models/stock_quantity.dart';
import '../controllers/recipe_controller.dart';

/// The form for adding an ingredient to a recipe, or changing how much of one is used.
///
/// ## Per sold unit
///
/// The quantity is what ONE of the dish uses. That is said on the form, because it is
/// the one thing an operator can get wrong here in a way nothing later would catch: a
/// figure entered per tray instead of per pizza would deduct ten times too much and look
/// entirely plausible on screen.
///
/// ## Where the choices come from
///
/// The ingredient list is the outlet's own stock items, and it excludes anything this
/// recipe already uses, so a duplicate cannot be offered. Nothing is suggested, prefilled
/// or exemplified.
class RecipeIngredientEditor extends StatefulWidget {
  const RecipeIngredientEditor({
    required this.controller,
    this.ingredient,
    super.key,
  });

  /// Opens the form for a new ingredient. Returns true when one was added.
  static Future<bool> add(
    BuildContext context, {
    required RecipeController controller,
  }) async {
    final bool? added = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          RecipeIngredientEditor(controller: controller),
    );
    return added ?? false;
  }

  /// Opens the form to change [ingredient]'s quantity. Returns true when it changed.
  static Future<bool> edit(
    BuildContext context, {
    required RecipeController controller,
    required RecipeIngredient ingredient,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => RecipeIngredientEditor(
        controller: controller,
        ingredient: ingredient,
      ),
    );
    return saved ?? false;
  }

  final RecipeController controller;

  /// The line being edited, or `null` when adding one.
  final RecipeIngredient? ingredient;

  @override
  State<RecipeIngredientEditor> createState() => _RecipeIngredientEditorState();
}

class _RecipeIngredientEditorState extends State<RecipeIngredientEditor> {
  late final TextEditingController _quantity = TextEditingController(
    text: widget.ingredient?.quantityDisplay ?? '',
  );

  /// The stock item chosen. Fixed when editing: changing which ingredient a line refers
  /// to is removing one line and adding another, and doing it silently would leave the
  /// quantity attached to something the operator did not check it against.
  late InventoryItem? _chosen = widget.ingredient == null
      ? null
      : widget.controller.stockItemFor(widget.ingredient!);

  String? _validation;

  bool get _isNew => widget.ingredient == null;

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<InventoryItem> choices = widget.controller.availableStockItems;
    final String? repositoryError = widget.controller.errorMessage;

    return AlertDialog(
      title: Text(_isNew ? 'Add ingredient' : 'Edit quantity'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_isNew)
                DropdownButtonFormField<InventoryItem>(
                  initialValue: _chosen,
                  // The operator names their own stock items, so the width of the
                  // longest one is not something this form can assume.
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Ingredient'),
                  items: <DropdownMenuItem<InventoryItem>>[
                    for (final InventoryItem item in choices)
                      DropdownMenuItem<InventoryItem>(
                        value: item,
                        child: Text(
                          '${item.name} (${item.unit.code})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (InventoryItem? item) =>
                      setState(() => _chosen = item),
                )
              else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_chosen?.name ?? 'Unknown stock item'),
                  subtitle: const Text('Ingredient'),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _quantity,
                autofocus: !_isNew,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _chosen == null
                      ? 'Quantity for one'
                      : 'Quantity for one (${_chosen!.unit.code})',
                  helperText:
                      'How much ONE of this item uses. Selling two deducts '
                      'twice this.',
                ),
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
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.controller.isSaving ? null : _save,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final InventoryItem? chosen = _chosen;
    if (chosen == null) {
      setState(() => _validation = 'Choose an ingredient.');
      return;
    }

    final int? quantity = StockQuantity.tryParse(_quantity.text.trim());
    if (quantity == null) {
      setState(
        () => _validation =
            'Enter the quantity as a number, up to three decimal places.',
      );
      return;
    }
    if (quantity <= 0) {
      setState(
        () => _validation =
            'A recipe has to use more than nothing of an ingredient.',
      );
      return;
    }

    setState(() => _validation = null);

    final RecipeIngredient? existing = widget.ingredient;
    final bool saved = existing == null
        ? await widget.controller.addIngredient(
            inventoryItemId: chosen.id,
            quantityMilli: quantity,
          )
        : await widget.controller.updateIngredientQuantity(
            ingredient: existing,
            quantityMilli: quantity,
          );

    if (saved && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
