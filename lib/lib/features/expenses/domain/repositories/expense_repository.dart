import '../../../../core/utils/result.dart';
import '../models/expense.dart';

/// Read and write access to expenses.
abstract interface class ExpenseRepository {
  /// Saves a new expense.
  Future<Result<void>> save(Expense expense);

  /// Loads expenses for today.
  Future<Result<List<Expense>>> loadToday();

  /// Soft-deletes an expense.
  Future<Result<void>> delete(String id);
}
