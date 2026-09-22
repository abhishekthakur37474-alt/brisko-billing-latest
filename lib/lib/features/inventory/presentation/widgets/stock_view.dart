import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/models/inventory_item.dart';
import '../../domain/models/order_inventory_deduction.dart';
import '../../domain/models/stock_movement_type.dart';
import '../controllers/inventory_controller.dart';
import 'inventory_item_editor.dart';
import 'inventory_notices.dart';
import 'stock_history_view.dart';
import 'stock_movement_editor.dart';

/// The shelves: every stock item, its balance, and whether it is running low.
///
/// Reads [InventoryController] and nothing else. There is no SQL here, no balance
/// arithmetic, and no table name; a row on screen is a row that was stored.
class StockView extends StatelessWidget {
  const StockView({super.key});

  @override
  Widget build(BuildContext context) {
    final InventoryController controller = context.watch<InventoryController>();

    return Column(
      children: <Widget>[
        _StockHeader(controller: controller),
        if (controller.hasError)
          InventoryErrorBanner(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
            onDismiss: controller.dismissError,
          ),
        Expanded(child: _StockBody(controller: controller)),
      ],
    );
  }
}

class _StockHeader extends StatelessWidget {
  const _StockHeader({required this.controller});

  final InventoryController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Text('Stock items', style: theme.textTheme.titleLarge),
                if (controller.hasLowStock) ...<Widget>[
                  const SizedBox(width: 12),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AppColors.pending,
                    ),
                    label: Text('${controller.lowStockCount} low'),
                  ),
                ],
              ],
            ),
          ),
          if (controller.isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          TextButton.icon(
            onPressed: controller.isLoading ? null : controller.refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () =>
                InventoryItemEditor.show(context, controller: controller),
            icon: const Icon(Icons.add),
            label: const Text('Add item'),
          ),
        ],
      ),
    );
  }
}

class _StockBody extends StatelessWidget {
  const _StockBody({required this.controller});

  final InventoryController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.isEmpty && !controller.hasFailedDeductions) {
      return InventoryEmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No stock items yet',
        message:
            'Add the raw materials the kitchen uses. Once a dish has a recipe, '
            'settling a bill takes its ingredients off the shelf automatically.',
        action: FilledButton.icon(
          onPressed: () =>
              InventoryItemEditor.show(context, controller: controller),
          icon: const Icon(Icons.add),
          label: const Text('Add the first item'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        if (controller.hasFailedDeductions)
          _FailedDeductions(controller: controller),
        if (controller.hasUnconfiguredDeductions)
          _UnconfiguredDeductions(controller: controller),
        for (final InventoryItem item in controller.items)
          _StockRow(controller: controller, item: item),
      ],
    );
  }
}

/// One shelf.
class _StockRow extends StatelessWidget {
  const _StockRow({required this.controller, required this.item});

  final InventoryController controller;

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    item.isMonitored
                        ? 'Low below ${item.minimumQuantityWithUnit}'
                        : 'Not monitored',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (item.isLow) ...<Widget>[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: AppColors.pending,
                    ),
                    const SizedBox(width: 6),
                    // The word, not just the colour. A colour alone is invisible to
                    // anyone who cannot distinguish it.
                    Text(
                      'Low',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: AppColors.pending,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Text(
                    item.currentQuantityWithUnit,
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _RowActions(controller: controller, item: item),
          ],
        ),
      ),
    );
  }
}

/// The per-item actions.
///
/// Stock in is a button of its own because it is the one done many times a day. The rest
/// are in a menu: a row with six buttons on it is a row nobody can read at a glance.
class _RowActions extends StatelessWidget {
  const _RowActions({required this.controller, required this.item});

  final InventoryController controller;

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        OutlinedButton(
          onPressed: () => StockMovementEditor.show(
            context,
            controller: controller,
            item: item,
            type: StockMovementType.stockIn,
          ),
          child: const Text('Stock in'),
        ),
        PopupMenuButton<_RowAction>(
          tooltip: 'More actions for ${item.name}',
          onSelected: (_RowAction action) => _run(context, action),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<_RowAction>>[
            for (final _RowAction action in _RowAction.values)
              PopupMenuItem<_RowAction>(
                value: action,
                child: Row(
                  children: <Widget>[
                    Icon(action.icon, size: 18),
                    const SizedBox(width: 12),
                    Text(action.label),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _run(BuildContext context, _RowAction action) async {
    switch (action) {
      case _RowAction.adjustment:
        await StockMovementEditor.show(
          context,
          controller: controller,
          item: item,
          type: StockMovementType.adjustment,
        );
      case _RowAction.wastage:
        await StockMovementEditor.show(
          context,
          controller: controller,
          item: item,
          type: StockMovementType.wastage,
        );
      case _RowAction.stockOut:
        await StockMovementEditor.show(
          context,
          controller: controller,
          item: item,
          type: StockMovementType.stockOut,
        );
      case _RowAction.history:
        await StockHistoryView.show(
          context,
          controller: controller,
          item: item,
        );
      case _RowAction.edit:
        await InventoryItemEditor.show(
          context,
          controller: controller,
          item: item,
        );
      case _RowAction.delete:
        await controller.deleteItem(item);
    }
  }
}

enum _RowAction {
  adjustment(label: 'Adjustment', icon: Icons.tune),
  wastage(label: 'Record wastage', icon: Icons.delete_sweep_outlined),
  stockOut(label: 'Stock out', icon: Icons.output),
  history(label: 'View history', icon: Icons.history),
  edit(label: 'Edit item', icon: Icons.edit_outlined),
  delete(label: 'Delete item', icon: Icons.delete_outline);

  const _RowAction({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

/// Settled bills whose stock was never taken off the shelf.
///
/// The owner's work list, and the reason a failed deduction is written down rather than
/// shown once at the till. Each bill here is a complete, paid sale; what is outstanding
/// is a stock figure. The usual fix is to record the delivery that was missed and then
/// retry, which is safe to press as often as needed.
class _FailedDeductions extends StatelessWidget {
  const _FailedDeductions({required this.controller});

  final InventoryController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.report_problem_outlined,
                  size: 20,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Stock not deducted for '
                    '${controller.failedDeductions.length} settled '
                    '${controller.failedDeductions.length == 1 ? 'bill' : 'bills'}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'These bills are settled and paid. Correct the stock they need, '
              'then retry.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            for (final OrderInventoryDeduction deduction
                in controller.failedDeductions) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Bill ${deduction.orderNumberSnapshot}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        if (deduction.failureMessage != null)
                          Text(
                            deduction.failureMessage!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: controller.isRetrying(deduction.orderId)
                        ? null
                        : () => controller.retryDeduction(deduction),
                    child: Text(
                      controller.isRetrying(deduction.orderId)
                          ? 'Retrying'
                          : 'Retry',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bills that sold something with no recipe configured.
///
/// Informational rather than a fault: these bills are processed and closed, and stock
/// was correctly not guessed at for them. The list exists so the owner can see which
/// dishes are still unaccounted for and write their recipes, which is how an outlet
/// goes live with no recipes and fills them in over its first weeks.
class _UnconfiguredDeductions extends StatelessWidget {
  const _UnconfiguredDeductions({required this.controller});

  final InventoryController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // Named once each, however many bills mentioned them. The owner needs the list of
    // dishes to configure, not the list of bills.
    final Set<String> dishes = <String>{
      for (final OrderInventoryDeduction deduction
          in controller.unconfiguredDeductions)
        ...deduction.unconfiguredItems,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.menu_book_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Recipe not configured',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'These items have been sold but use no stock, because nothing is '
              'configured for them: ${dishes.join(', ')}. '
              'Set their recipes under Recipes to have stock deducted in future.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
