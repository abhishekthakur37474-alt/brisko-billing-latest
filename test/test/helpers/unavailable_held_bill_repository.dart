import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_draft.dart';
import 'package:brisko_billing/features/billing/domain/models/held_bill_summary.dart';
import 'package:brisko_billing/features/billing/domain/repositories/held_bill_repository.dart';

/// A [HeldBillRepository] that refuses everything with a storage failure.
///
/// Stands in for a terminal whose held-bill storage cannot be reached, so the screen's
/// error path — the retry, the message, the fact that a failed hold keeps the bill — can
/// be exercised without breaking a real database. Every method returns the same
/// [LocalStorageFailure] carrying [message], which is what the tests look for on screen.
class UnavailableHeldBillRepository implements HeldBillRepository {
  const UnavailableHeldBillRepository();

  /// What the cashier is shown for any held-bill operation against this repository.
  static const String message = 'The held bills are unavailable.';

  @override
  Future<Result<HeldBill>> hold(HeldBillDraft draft) => _refuse<HeldBill>();

  @override
  Future<Result<HeldBill?>> findHeldBill(String id) => _refuse<HeldBill?>();

  @override
  Future<Result<List<HeldBillSummary>>> loadHeldBills() =>
      _refuse<List<HeldBillSummary>>();

  @override
  Future<Result<HeldBill>> resume(String id) => _refuse<HeldBill>();

  @override
  Future<Result<HeldBill>> cancel(String id) => _refuse<HeldBill>();

  static Future<Result<T>> _refuse<T>() async =>
      const Err<Never>(LocalStorageFailure(message));
}
