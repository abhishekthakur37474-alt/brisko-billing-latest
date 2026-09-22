import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/models/inventory_item.dart';
import '../../domain/models/stock_movement.dart';
import '../controllers/inventory_controller.dart';
import 'inventory_notices.dart';

/// One stock item's ledger: every movement, newest first.
///
/// ## Why the reference is shown
///
/// It is what makes a row explicable. A sale deduction carries the settled bill's id, so
/// a balance that looks wrong can be traced to the bills that moved it. Manual movements
/// carry no reference and carry their reason instead, which is the operator's own account
/// of what happened. Between them, every change to a balance can be accounted for.
///
/// Nothing is synthesised. An item that has never moved shows an empty ledger.
class StockHistoryView extends StatelessWidget {
  const StockHistoryView({required this.item, super.key});

  /// Opens the ledger for [item] and closes it again on dismissal.
  static Future<void> show(
    BuildContext context, {
    required InventoryController controller,
    required InventoryItem item,
  }) async {
    await controller.openHistory(item.id);
    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) =>
          ChangeNotifierProvider<InventoryController>.value(
            value: controller,
            child: StockHistoryView(item: item),
          ),
    );
    controller.closeHistory();
  }

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final InventoryController controller = context.watch<InventoryController>();
    final ThemeData theme = Theme.of(context);
    final List<StockMovement> movements = controller.history;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('${item.name} history'),
          const SizedBox(height: 4),
          Text(
            'In stock now: ${item.currentQuantityWithUnit}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: switch (controller) {
          InventoryController(isLoadingHistory: true) => const Center(
            child: CircularProgressIndicator(),
          ),
          _ when movements.isEmpty => const InventoryEmptyState(
            icon: Icons.history,
            title: 'No movements yet',
            message:
                'Every change to this balance appears here: stock received, '
                'wastage, corrections, and the stock a settled bill used.',
          ),
          _ => ListView.separated(
            itemCount: movements.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                _MovementRow(item: item, movement: movements[index]),
          ),
        },
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.item, required this.movement});

  final InventoryItem item;

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isIncrease = movement.signedQuantityMilli > 0;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              movement.movementType.label,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            item.unit.describe(movement.signedQuantityDisplay),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isIncrease
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.error,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _timestamp(movement.createdAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (movement.reason != null)
            Text(movement.reason!, style: theme.textTheme.bodySmall),
          if (movement.referenceId != null)
            Text(
              // Named as a bill for a sale, and as a plain reference otherwise, so a
              // row is not labelled something it is not.
              movement.isSale
                  ? 'Bill ${movement.referenceId}'
                  : 'Reference ${movement.referenceId}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  /// Local date and time, to the minute.
  ///
  /// Stored in UTC and rendered local, because a movement is read against the shift it
  /// happened on. Formatted here rather than through a locale package: the application
  /// has no localisation yet, and adding one for a timestamp is not this step's work.
  static String _timestamp(DateTime utc) {
    final DateTime at = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.day)}/${two(at.month)}/${at.year} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}
