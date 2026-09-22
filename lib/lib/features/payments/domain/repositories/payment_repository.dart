import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../models/payment.dart';
import '../models/payment_method.dart';

/// Read and write access to payments.
abstract interface class PaymentRepository {
  Future<Result<void>> record(Payment payment);

  /// Every payment against an order, oldest first. Several rows means a split
  /// payment.
  Future<Result<List<Payment>>> loadForOrder(String orderId);

  /// How each of several orders was settled, keyed by order id.
  ///
  /// Exists so a list of bills can show how each was paid without one query per row.
  /// Only settled tenders are considered, so a pending attempt does not make a bill look
  /// paid, and an order with none is absent from the map rather than present with a
  /// guess.
  ///
  /// Where a bill has more than one settled tender the earliest is reported, matching
  /// what the receipt prints. Split payment is a later feature and this is one of the
  /// lines that changes when it arrives.
  Future<Result<Map<String, PaymentMethod>>> loadSettledMethodsForOrders(
    Iterable<String> orderIds,
  );

  /// Total of the settled payments against an order.
  ///
  /// Only completed payments count, so a pending UPI attempt does not make a bill
  /// look paid.
  Future<Result<Money>> settledTotalForOrder(String orderId);

  Future<Result<void>> updateStatusFor(String paymentId, Payment payment);

  Future<Result<void>> delete(String id);
}
