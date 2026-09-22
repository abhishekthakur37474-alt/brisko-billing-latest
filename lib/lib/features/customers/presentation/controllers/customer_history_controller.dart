import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_item.dart';
import '../../../orders/domain/repositories/order_repository.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../payments/domain/repositories/payment_repository.dart';
import '../../domain/models/customer_summary.dart';
import '../../domain/repositories/customer_repository.dart';

/// Holds one customer: their totals, and every bill they have been given.
///
/// ## Where the history comes from
///
/// The `orders` table, through [OrderRepository]. Each row on screen is a bill that was
/// settled, showing the number, the time, the order type and the total that were written
/// at the moment of sale. The line summary beside it comes from the stored
/// `order_items` snapshots.
///
/// Nothing here reads the menu. That is the whole point of the history: repricing a dish,
/// renaming it or deleting it outright changes what the next bill will say, and cannot
/// change what any past bill said.
///
/// ## What is counted
///
/// [summary] holds the count, the spend and the last visit, aggregated by the repository
/// from settled bills only. [orders] holds every stored bill including a cancelled one,
/// because a cancellation happened and hiding it would misrepresent the record. The two
/// answer different questions and are deliberately not derived from each other.
///
/// ## Money
///
/// Every amount is a [Money] in integer paise, read from the stored `Paise` columns.
/// Nothing on this path parses a decimal or touches a [double].
class CustomerHistoryController extends ChangeNotifier {
  CustomerHistoryController({
    required this._customerId,
    required CustomerRepository customerRepository,
    required OrderRepository orderRepository,
    required PaymentRepository paymentRepository,
  }) : _customers = customerRepository,
       _orders = orderRepository,
       _payments = paymentRepository;

  final String _customerId;
  final CustomerRepository _customers;
  final OrderRepository _orders;
  final PaymentRepository _payments;

  CustomerSummary? _summary;
  List<Order> _orderHistory = const <Order>[];
  Map<String, List<OrderItem>> _linesByOrder =
      const <String, List<OrderItem>>{};
  Map<String, PaymentMethod> _methodsByOrder = const <String, PaymentMethod>{};

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // ------------------------------------------------------------------- state ---

  String get customerId => _customerId;

  /// The customer with their totals, or `null` before the read or if the record is gone.
  CustomerSummary? get summary => _summary;

  /// Every stored bill for this customer, newest first.
  List<Order> get orders => _orderHistory;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the read finished and this customer has no bills.
  ///
  /// Reachable: a record can exist with nothing against it. Shown as such rather than
  /// treated as an error.
  bool get isEmpty => _hasLoaded && !hasError && _orderHistory.isEmpty;

  /// True when the read finished and the customer record is not on this terminal.
  bool get isMissing => _hasLoaded && !hasError && _summary == null;

  // ----------------------------------------------------------------- derived ---

  String? get phone => _summary?.phone;

  /// Settled bills against this customer.
  int get completedOrderCount => _summary?.completedOrderCount ?? 0;

  /// Sum of the settled bills' persisted totals, before any reversal. Exact.
  Money get totalSpent => _summary?.totalSpent ?? Money.zero;

  /// Money handed back to this customer, as a positive amount.
  Money get refundedTotal => _summary?.refundedTotal ?? Money.zero;

  /// What this customer has actually paid: [totalSpent] less [refundedTotal].
  ///
  /// The figure the counter should read. [totalSpent] stays available beside it so a
  /// refunded customer's record shows both what they were billed and what they kept.
  Money get netSpent => _summary?.netSpent ?? Money.zero;

  /// True when any money has been handed back to this customer.
  bool get hasRefunds => _summary?.hasRefunds ?? false;

  /// The most recent stored bill, or `null` when there is none.
  ///
  /// Taken from the head of the history, which the repository returns newest first.
  Order? get mostRecentOrder =>
      _orderHistory.isEmpty ? null : _orderHistory.first;

  /// The stored lines on [order], oldest first. Empty when none were found.
  List<OrderItem> linesOf(Order order) =>
      _linesByOrder[order.id] ?? const <OrderItem>[];

  /// How [order] was settled, or `null` when no settled tender is stored against it.
  ///
  /// `null` rather than a default. A bill with no recorded payment is a bill nobody
  /// should be told was paid by cash.
  PaymentMethod? paymentMethodOf(Order order) => _methodsByOrder[order.id];

  /// A short description of what a bill contained, built from its stored lines.
  ///
  /// For example `2 x Cheese Pizza (Medium), 1 x French Fries`. The names are the
  /// snapshots taken when the bill was settled, so this text does not change when the
  /// menu does.
  ///
  /// Returns `null` when no lines are stored, so the view can say so rather than print
  /// an empty string.
  String? itemSummaryOf(Order order) {
    final List<OrderItem> lines = linesOf(order);
    if (lines.isEmpty) {
      return null;
    }
    return lines
        .map((OrderItem line) => '${line.quantity} x ${line.displayName}')
        .join(', ');
  }

  // ----------------------------------------------------------------- reading ---

  /// Reads the customer, their totals and their bills.
  ///
  /// Ignores a call made while a read is already running.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<CustomerSummary?> summary = await _customers.loadSummary(
      _customerId,
    );
    final AppFailure? summaryFailure = summary.failureOrNull;
    if (summaryFailure != null) {
      _fail(summaryFailure.message);
      return;
    }

    final CustomerSummary? found = summary.valueOrNull;
    if (found == null) {
      // The record is not here. A different thing to report than a storage fault.
      _clear();
      _finish();
      return;
    }

    final Result<List<Order>> history = await _orders.loadOrdersForCustomer(
      _customerId,
    );
    final AppFailure? historyFailure = history.failureOrNull;
    if (historyFailure != null) {
      _fail(historyFailure.message);
      return;
    }

    final List<Order> stored = history.valueOrNull!;

    final Iterable<String> orderIds = stored.map((Order order) => order.id);

    // One read for the lines of every bill, rather than one per bill.
    final Result<Map<String, List<OrderItem>>> lines = await _orders
        .loadItemsForOrders(orderIds);
    final AppFailure? lineFailure = lines.failureOrNull;
    if (lineFailure != null) {
      _fail(lineFailure.message);
      return;
    }

    // Likewise one read for how they were all paid.
    final Result<Map<String, PaymentMethod>> methods = await _payments
        .loadSettledMethodsForOrders(orderIds);
    final AppFailure? methodFailure = methods.failureOrNull;
    if (methodFailure != null) {
      _fail(methodFailure.message);
      return;
    }

    _summary = found;
    _orderHistory = stored;
    _linesByOrder = lines.valueOrNull!;
    _methodsByOrder = methods.valueOrNull!;
    _finish();
  }

  Future<void> retry() => load();

  // --------------------------------------------------------------- internals ---

  /// Reports a read that failed, showing no part of the customer.
  ///
  /// Totals beside a message saying the bills could not be read would be a figure nobody
  /// should quote, so everything is cleared.
  void _fail(String message) {
    _errorMessage = message;
    _clear();
    _finish();
  }

  void _clear() {
    _summary = null;
    _orderHistory = const <Order>[];
    _linesByOrder = const <String, List<OrderItem>>{};
    _methodsByOrder = const <String, PaymentMethod>{};
  }

  void _finish() {
    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
