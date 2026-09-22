import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money.dart';
import '../../../orders/domain/repositories/order_repository.dart';
import '../../domain/models/expense.dart';
import '../../domain/repositories/expense_repository.dart';
import '../controllers/expenses_controller.dart';

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ExpensesController>(
      create: (BuildContext context) {
        final ExpensesController controller = ExpensesController(
          expenseRepository: context.read<ExpenseRepository>(),
          orderRepository: context.read<OrderRepository>(),
        );
        controller.load();
        return controller;
      },
      child: const _ExpensesBody(),
    );
  }
}

class _ExpensesBody extends StatelessWidget {
  const _ExpensesBody();

  @override
  Widget build(BuildContext context) {
    final ExpensesController controller = context.watch<ExpensesController>();
    final ThemeData theme = Theme.of(context);

    if (controller.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Expenses & Profit')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (controller.hasError)
            Container(
              padding: const EdgeInsets.all(16),
              color: theme.colorScheme.errorContainer,
              child: Text(
                controller.errorMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text("Today's Overview", style: theme.textTheme.titleMedium),
                    const SizedBox(height: 16),
                    _SummaryRow(label: 'Sales', amount: controller.todaySales),
                    _SummaryRow(label: 'Expenses', amount: controller.todayExpenses, isDeduction: true),
                    const Divider(),
                    _SummaryRow(
                      label: 'Profit', 
                      amount: controller.todayProfit, 
                      isTotal: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text('Expenses', style: theme.textTheme.titleMedium),
                FilledButton.icon(
                  onPressed: () => _showAddExpenseDialog(context, controller),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Expense'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: controller.expenses.isEmpty
                ? const Center(child: Text('No expenses recorded today.'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: controller.expenses.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Expense expense = controller.expenses[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(expense.name),
                          subtitle: expense.note != null && expense.note!.isNotEmpty
                              ? Text(expense.note!)
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '\u20B9${expense.amount.toDecimalString()}',
                                style: theme.textTheme.titleSmall,
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => controller.deleteExpense(expense.id),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddExpenseDialog(
    BuildContext context,
    ExpensesController controller,
  ) async {
    final TextEditingController nameController = TextEditingController();
    final TextEditingController amountController = TextEditingController();
    final TextEditingController noteController = TextEditingController();

    try {
      final bool? added = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Add Expense'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Expense Name (e.g. Vegetables)'),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  decoration: const InputDecoration(labelText: 'Amount'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'Note (Optional)'),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final double? parsedAmount = double.tryParse(amountController.text);
                  if (nameController.text.trim().isEmpty || parsedAmount == null || parsedAmount <= 0) {
                    return; // Basic validation
                  }
                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      );

      if (added ?? false) {
        final double amountDouble = double.parse(amountController.text);
        final Money amount = Money.fromPaise((amountDouble * 100).round());
        await controller.addExpense(
          nameController.text.trim(),
          amount,
          noteController.text.trim(),
        );
      }
    } finally {
      nameController.dispose();
      amountController.dispose();
      noteController.dispose();
    }
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.amount,
    this.isDeduction = false,
    this.isTotal = false,
  });

  final String label;
  final Money amount;
  final bool isDeduction;
  final bool isTotal;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = isTotal ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium;
    final Color? color = isDeduction ? theme.colorScheme.error : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: style),
          Text(
            isDeduction ? '- \u20B9${amount.toDecimalString()}' : '\u20B9${amount.toDecimalString()}',
            style: style?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
