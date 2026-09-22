import 'package:flutter/foundation.dart';

import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_status.dart';
import '../../../orders/domain/repositories/order_repository.dart';
import '../../domain/models/expense.dart';
import '../../domain/repositories/expense_repository.dart';

class ExpensesController extends ChangeNotifier {
  ExpensesController({
    required this.expenseRepository,
    required this.orderRepository,
  });

  final ExpenseRepository expenseRepository;
  final OrderRepository orderRepository;

  List<Expense> _expenses = const <Expense>[];
  Money _todaySales = Money.zero;

  bool _isLoading = false;
  String? _errorMessage;

  List<Expense> get expenses => _expenses;
  Money get todaySales => _todaySales;
  Money get todayExpenses => Money.sum(_expenses.map((e) => e.amount));
  Money get todayProfit => todaySales - todayExpenses;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get hasError => _errorMessage != null;

  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // Load today's expenses
    final Result<List<Expense>> expensesResult = await expenseRepository.loadToday();
    if (expensesResult.isErr) {
      _errorMessage = expensesResult.failureOrNull!.message;
      _isLoading = false;
      notifyListeners();
      return;
    }

    // Load today's sales (only completed orders)
    final DateTime now = DateTime.now();
    final DateTime startOfDay = DateTime(now.year, now.month, now.day);
    final DateTime endOfDay = startOfDay.add(const Duration(days: 1));
    
    final Result<List<Order>> ordersResult = await orderRepository.loadOrders(
      from: startOfDay,
      to: endOfDay,
      status: OrderStatus.completed,
    );
    if (ordersResult.isErr) {
      _errorMessage = ordersResult.failureOrNull!.message;
      _isLoading = false;
      notifyListeners();
      return;
    }

    _expenses = expensesResult.valueOrNull!;
    _todaySales = Money.sum(ordersResult.valueOrNull!.map((o) => o.totalAmount));

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> addExpense(String name, Money amount, String? note) async {
    final DateTime now = DateTime.now();
    final Expense expense = Expense(
      id: now.millisecondsSinceEpoch.toString(),
      name: name,
      amount: amount,
      note: note,
      createdAt: now,
      updatedAt: now,
    );

    final Result<void> result = await expenseRepository.save(expense);
    if (result.isErr) {
      _errorMessage = result.failureOrNull!.message;
      notifyListeners();
      return false;
    }

    await load();
    return true;
  }

  Future<bool> deleteExpense(String id) async {
    final Result<void> result = await expenseRepository.delete(id);
    if (result.isErr) {
      _errorMessage = result.failureOrNull!.message;
      notifyListeners();
      return false;
    }

    await load();
    return true;
  }
}
