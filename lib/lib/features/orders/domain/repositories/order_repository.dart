import '../../../../core/utils/result.dart';
import '../models/bill_line_snapshot.dart';
import '../models/order.dart';
import '../models/order_cancellation.dart';
import '../models/order_item.dart';
import '../models/order_item_option.dart';
import '../models/order_status.dart';

/// Read and write access to orders and their lines.
abstract interface class OrderRepository {
  /// Saves an order together with its lines and their options, atomically.
  ///
  /// One call rather than three, because a bill with a header but no lines is not
  /// a valid business record. Either all of it lands or none of it does.
  Future<Result<void>> saveOrder(
    Order order, {
    List<OrderItem> items,
    List<OrderItemOption> itemOptions,
  });

  Future<Result<Order?>> findOrder(String id);

  Future<Result<Order?>> findOrderByNumber(String orderNumber);

  /// Lines on an order, in the sequence they were added.
  Future<Result<List<OrderItem>>> loadItems(String orderId);

  /// Options applied to one line.
  Future<Result<List<OrderItemOption>>> loadItemOptions(String orderItemId);

  /// A stored bill's lines with their options already paired up, in bill order.
  ///
  /// What a historical bill is displayed from. Everything returned is a snapshot taken
  /// at the moment of sale — names, sizes, unit prices, option prices — so reopening a
  /// bill after the menu has been repriced, renamed or partly deleted shows what the
  /// customer was actually charged.
  Future<Result<List<BillLineSnapshot>>> loadBillLines(String orderId);

  /// Lines for several orders at once, keyed by order id.
  ///
  /// Exists so a customer's history can show what each bill contained without one query
  /// per bill. Options are not included: a history list summarises the dishes, and the
  /// customisations belong on the bill itself.
  ///
  /// Orders with no lines are absent from the map rather than present and empty.
  Future<Result<Map<String, List<OrderItem>>>> loadItemsForOrders(
    Iterable<String> orderIds,
  );

  /// Orders within a time window, newest first.
  ///
  /// [from] is inclusive and [to] exclusive, which makes "one day" expressible
  /// without worrying about the last millisecond of the day.
  Future<Result<List<Order>>> loadOrders({
    DateTime? from,
    DateTime? to,
    OrderStatus? status,
    int limit,
  });

  /// A customer's order history, newest first.
  ///
  /// Derived from the orders table rather than stored on the customer, so it can
  /// never disagree with the bills themselves.
  ///
  /// Every status is returned, including a cancelled bill. A cancellation happened and
  /// belongs in the history; what it does not do is count towards the customer's totals,
  /// which is a separate question answered by `CustomerSummary`.
  Future<Result<List<Order>>> loadOrdersForCustomer(
    String customerId, {
    int limit,
  });

  /// Reserves the next human-readable order number for today.
  Future<Result<String>> nextOrderNumber();

  Future<Result<void>> updateStatus(String orderId, OrderStatus status);

  /// Cancels a written bill and returns it as it now stands.
  ///
  /// A status change and nothing more. The row is not deleted, no stored amount is
  /// rewritten, the lines and their options stay, and the tender stays exactly as it was
  /// recorded — so a cancelled bill can still be opened and read. What it stops is
  /// outstanding kitchen work, in the same transaction, because a bill nobody is paying
  /// for must not leave food being cooked for it. Stock is deliberately not given back.
  /// Every one of those decisions is named on [OrderCancellation].
  ///
  /// Fails with a `ValidationFailure` when the bill is not on this terminal or has
  /// already been cancelled. The check and the write share one transaction, so two
  /// simultaneous cancellations resolve to one winner rather than both succeeding.
  Future<Result<Order>> cancelOrder(
    String orderId, {
    String? cancellationReason,
    String? authorizedBy,
  });

  /// Soft-deletes the order. Lines are left in place and are unreachable through
  /// [loadItems] only if they are themselves deleted, so history stays auditable.
  Future<Result<void>> deleteOrder(String id);
}
