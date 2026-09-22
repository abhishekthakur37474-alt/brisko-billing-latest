import 'package:flutter/material.dart';

import '../../domain/models/inventory_item.dart';
import '../../domain/models/stock_movement_type.dart';
import '../../domain/models/stock_quantity.dart';
import '../controllers/inventory_controller.dart';

/// The form for recording a manual stock movement: stock in, an adjustment, wastage or
/// a stock out.
///
/// ## One form for four operations
///
/// They differ only in what is being claimed about the quantity, so they share a form
/// and the type decides the wording, whether a sign is allowed, and what is checked. Four
/// near-identical dialogs would have drifted apart on the details that matter, such as
/// whether a negative figure is accepted.
///
/// ## What is not checked here
///
/// Whether there is enough stock. This form refuses a quantity that is not a number, and
/// it refuses zero, because those are facts about the text. Whether the shelf can cover
/// a withdrawal is a fact about the database at the instant of the write, so it is
/// checked by the repository inside the transaction that does it, and its refusal is
/// shown here. Checking it on the form as well would be a second answer that could
/// disagree with the first.
class StockMovementEditor extends StatefulWidget {
  const StockMovementEditor({
    required this.controller,
    required this.item,
    required this.type,
    super.key,
  });

  /// Opens the form. Returns true when a movement was recorded.
  static Future<bool> show(
    BuildContext context, {
    required InventoryController controller,
    required InventoryItem item,
    required StockMovementType type,
  }) async {
    final bool? recorded = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          StockMovementEditor(controller: controller, item: item, type: type),
    );
    return recorded ?? false;
  }

  final InventoryController controller;

  final InventoryItem item;

  final StockMovementType type;

  @override
  State<StockMovementEditor> createState() => _StockMovementEditorState();
}

class _StockMovementEditorState extends State<StockMovementEditor> {
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  /// True when an adjustment is reducing the balance.
  ///
  /// A separate control rather than a minus typed into the number, because an
  /// adjustment is the one movement whose direction the operator chooses, and a leading
  /// `-` is easy to miss on a figure being read back.
  bool _isReduction = false;

  String? _validation;

  bool get _isAdjustment => widget.type == StockMovementType.adjustment;

  @override
  void dispose() {
    _quantity.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? repositoryError = widget.controller.errorMessage;

    return AlertDialog(
      title: Text('${widget.type.label}: ${widget.item.name}'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'In stock now: ${widget.item.currentQuantityWithUnit}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (_isAdjustment) ...<Widget>[
                SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: false, label: Text('Add')),
                    ButtonSegment<bool>(value: true, label: Text('Remove')),
                  ],
                  selected: <bool>{_isReduction},
                  onSelectionChanged: (Set<bool> selection) {
                    setState(() => _isReduction = selection.first);
                  },
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _quantity,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText:
                      '${widget.type.quantityPrompt} '
                      '(${widget.item.unit.code})',
                  helperText: 'Up to three decimal places',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _reason,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Reason',
                  helperText: _reasonHelper,
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
              // The repository's refusal, most often not enough stock. Shown here with
              // the figures still on screen, so the operator can correct one of them.
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
          onPressed: widget.controller.isSaving ? null : _record,
          child: Text('Record ${widget.type.label.toLowerCase()}'),
        ),
      ],
    );
  }

  String get _reasonHelper => switch (widget.type) {
    StockMovementType.stockIn => 'Optional, for example who it came from',
    StockMovementType.adjustment => 'Optional, for example a monthly count',
    StockMovementType.wastage => 'Optional, for example spoiled or dropped',
    StockMovementType.stockOut => 'Optional, for example sent to an event',
    StockMovementType.sale => 'Optional',
  };

  Future<void> _record() async {
    final int? entered = StockQuantity.tryParse(_quantity.text.trim());

    if (entered == null) {
      setState(
        () => _validation =
            'Enter the quantity as a number, up to three decimal places.',
      );
      return;
    }
    if (entered <= 0) {
      setState(() => _validation = 'Enter a quantity greater than zero.');
      return;
    }

    // The magnitude is always positive here. Direction comes from the movement type,
    // except for an adjustment, where it comes from the Add/Remove control.
    final int quantityMilli = _isAdjustment && _isReduction
        ? -entered
        : entered;

    setState(() => _validation = null);

    final bool recorded = await widget.controller.recordMovement(
      item: widget.item,
      type: widget.type,
      quantityMilli: quantityMilli,
      reason: _reason.text,
    );

    if (recorded && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
