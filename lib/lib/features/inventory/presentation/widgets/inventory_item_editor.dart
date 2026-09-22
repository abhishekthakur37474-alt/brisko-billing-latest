import 'package:flutter/material.dart';

import '../../domain/models/inventory_item.dart';
import '../../domain/models/stock_quantity.dart';
import '../../domain/models/stock_unit.dart';
import '../controllers/inventory_controller.dart';

/// The form for creating or editing a stock item.
///
/// ## What it does not edit
///
/// The balance. A new item is created at zero and whatever is already on the shelf is
/// entered afterwards as stock in, so the figure has a ledger row behind it from the
/// start. Editing an existing item cannot touch its balance either — the repository
/// refuses such a save — which is why there is no quantity field here at all rather
/// than a disabled one.
///
/// That is stated on the form rather than left to be discovered, because "where do I
/// type how much flour I have" is the first question the form invites.
class InventoryItemEditor extends StatefulWidget {
  const InventoryItemEditor({required this.controller, this.item, super.key});

  /// Opens the form. Returns true when something was saved.
  static Future<bool> show(
    BuildContext context, {
    required InventoryController controller,
    InventoryItem? item,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          InventoryItemEditor(controller: controller, item: item),
    );
    return saved ?? false;
  }

  final InventoryController controller;

  /// The item being edited, or `null` when creating one.
  final InventoryItem? item;

  @override
  State<InventoryItemEditor> createState() => _InventoryItemEditorState();
}

class _InventoryItemEditorState extends State<InventoryItemEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.item?.name ?? '',
  );

  /// Pre-filled from the stored threshold, and blank rather than `0` when the item is
  /// not monitored, so an empty field reads as "no threshold" on the way in and out.
  late final TextEditingController _minimum = TextEditingController(
    text: widget.item == null || widget.item!.minimumQuantityMilli == 0
        ? ''
        : widget.item!.minimumQuantityDisplay,
  );

  late StockUnit _unit = widget.item?.unit ?? StockUnit.kilogram;

  String? _validation;

  bool get _isNew => widget.item == null;

  @override
  void dispose() {
    _name.dispose();
    _minimum.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? repositoryError = widget.controller.errorMessage;

    return AlertDialog(
      title: Text(_isNew ? 'Add stock item' : 'Edit stock item'),
      content: SizedBox(
        width: 400,
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
                  helperText: 'The raw material as the kitchen refers to it',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<StockUnit>(
                initialValue: _unit,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Unit'),
                items: <DropdownMenuItem<StockUnit>>[
                  for (final StockUnit unit in StockUnit.values)
                    DropdownMenuItem<StockUnit>(
                      value: unit,
                      child: Text(
                        '${unit.label} (${unit.code})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (StockUnit? chosen) {
                  if (chosen != null) {
                    setState(() => _unit = chosen);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _minimum,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Low stock threshold (${_unit.code})',
                  helperText:
                      'Leave blank to leave this item unmonitored. '
                      'At or below this, it is flagged as low.',
                ),
              ),
              if (_isNew) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  'The item starts at zero. Record what is already on the shelf '
                  'with Stock in, so the balance has a movement behind it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_validation != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  _validation!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              // A refusal from the repository, for example a name that collides or a
              // storage fault. Shown on the form so the operator does not lose what
              // they typed.
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

    // Blank means unmonitored, which is a threshold of zero. Anything else has to be
    // a real quantity: a typo here would silently switch monitoring off.
    final String minimumText = _minimum.text.trim();
    final int? minimum = minimumText.isEmpty
        ? StockQuantity.zero
        : StockQuantity.tryParse(minimumText);

    if (minimum == null) {
      setState(
        () => _validation =
            'Enter the threshold as a number, up to three decimal places.',
      );
      return;
    }
    if (minimum < 0) {
      setState(() => _validation = 'A threshold cannot be negative.');
      return;
    }

    setState(() => _validation = null);

    final InventoryItem? existing = widget.item;
    final bool saved = existing == null
        ? await widget.controller.createItem(
            name: name,
            unit: _unit,
            minimumQuantityMilli: minimum,
          )
        : await widget.controller.updateItem(
            existing,
            name: name,
            unit: _unit,
            minimumQuantityMilli: minimum,
          );

    if (saved && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
