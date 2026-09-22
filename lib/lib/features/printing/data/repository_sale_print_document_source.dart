import '../../../core/error/app_failure.dart';
import '../../../core/utils/result.dart';
import '../../billing/domain/models/bill_discount.dart';
import '../../billing/domain/models/gst_rate.dart';
import '../../customers/domain/models/customer.dart';
import '../../customers/domain/repositories/customer_repository.dart';
import '../../kot/domain/models/kitchen_ticket.dart';
import '../../kot/domain/models/kot_item_option.dart';
import '../../kot/domain/repositories/kot_repository.dart';
import '../../orders/domain/models/order.dart';
import '../../orders/domain/models/order_item.dart';
import '../../orders/domain/models/order_item_option.dart';
import '../../orders/domain/repositories/order_repository.dart';
import '../../payments/domain/models/payment.dart';
import '../../payments/domain/models/payment_status.dart';
import '../../payments/domain/repositories/payment_repository.dart';
import '../domain/models/business_identity.dart';
import '../domain/models/print_document.dart';
import '../domain/models/sale_print_documents.dart';
import '../domain/services/sale_print_document_source.dart';
import 'settings_business_identity_source.dart';

/// Builds print documents by reading the committed sale.
///
/// ## What it reads, and why from there
///
/// The order header, its lines and their options, the payment, the customer record and
/// the kitchen slips — all from the tables, none from the cart and none from the menu.
/// Reading the committed rows rather than the in-memory bill is what makes the paper
/// and the database provably the same document, and it is what lets a bill be reprinted
/// months later from nothing but its id.
///
/// ## What it never does
///
/// Write. There is no repository write in this file, which is the structural reason a
/// retry or a reprint cannot produce a second order, payment or kitchen slip.
class RepositorySalePrintDocumentSource implements SalePrintDocumentSource {
  const RepositorySalePrintDocumentSource({
    required this.orders,
    required this.payments,
    required this.kots,
    required this.customers,
    required this.identity,
  });

  final OrderRepository orders;
  final PaymentRepository payments;
  final KotRepository kots;
  final CustomerRepository customers;
  final SettingsBusinessIdentitySource identity;

  @override
  Future<Result<SalePrintDocuments>> forOrder(
    String orderId, {
    bool isReprint = false,
  }) async {
    final Result<Order?> found = await orders.findOrder(orderId);
    if (found.isErr) {
      return Err<SalePrintDocuments>(found.failureOrNull!);
    }

    final Order? order = found.valueOrNull;
    if (order == null) {
      return Err<SalePrintDocuments>(
        ValidationFailure(
          'That bill is no longer on this terminal, so it cannot be printed.',
        ),
      );
    }

    final Result<List<OrderItem>> lines = await orders.loadItems(orderId);
    if (lines.isErr) {
      return Err<SalePrintDocuments>(lines.failureOrNull!);
    }
    final List<OrderItem> items = lines.valueOrNull!;
    if (items.isEmpty) {
      return Err<SalePrintDocuments>(
        const ValidationFailure(
          'That bill has no lines, so there is nothing to print.',
        ),
      );
    }

    final Result<CustomerReceipt> receipt = await _receipt(
      order: order,
      items: items,
      isReprint: isReprint,
    );
    if (receipt.isErr) {
      return Err<SalePrintDocuments>(receipt.failureOrNull!);
    }

    final Result<List<KitchenKot>> slips = await _kots(
      order: order,
      isReprint: isReprint,
    );
    if (slips.isErr) {
      return Err<SalePrintDocuments>(slips.failureOrNull!);
    }

    return Ok<SalePrintDocuments>(
      SalePrintDocuments(
        receipt: receipt.valueOrNull!,
        kots: slips.valueOrNull!,
      ),
    );
  }

  // --------------------------------------------------------------- receipt ---

  Future<Result<CustomerReceipt>> _receipt({
    required Order order,
    required List<OrderItem> items,
    required bool isReprint,
  }) async {
    final Result<List<Payment>> tendered = await payments.loadForOrder(
      order.id,
    );
    if (tendered.isErr) {
      return Err<CustomerReceipt>(tendered.failureOrNull!);
    }

    final List<Payment> settled = tendered.valueOrNull!
        .where((Payment payment) => payment.status == PaymentStatus.completed)
        .toList(growable: false);

    if (settled.isEmpty) {
      return Err<CustomerReceipt>(
        const ValidationFailure(
          'That bill has no settled payment, so a receipt would say it was '
          'paid when it was not.',
        ),
      );
    }

    // Every figure from the committed order, including the rate it was charged at and the
    // discount rule it was given. Nothing is read from Settings: a bill reprinted after the
    // outlet changes slab must still say what it charged, and the only way to guarantee that
    // is never to ask the current configuration.
    final CustomerReceiptTotals totals = CustomerReceiptTotals(
      subtotal: order.subtotal,
      discount: order.discountAmount,
      tax: order.taxAmount,
      total: order.totalAmount,
      taxRate: GstRate.fromStoredBasisPoints(order.taxRateBasisPoints),
      discountLabel: BillDiscount.fromStored(
        storedType: order.discountType,
        storedValue: order.discountValue,
      )?.label,
    );

    // Exact paise on both sides, so this is a real check and not a tolerance.
    if (!totals.isConsistent) {
      return Err<CustomerReceipt>(
        const ValidationFailure(
          'That bill does not add up, so it has not been printed. Check the '
          'order before giving the customer a receipt.',
        ),
      );
    }

    final List<CustomerReceiptLine> lines = <CustomerReceiptLine>[];
    for (final OrderItem item in items) {
      final Result<List<OrderItemOption>> options = await orders
          .loadItemOptions(item.id);
      if (options.isErr) {
        return Err<CustomerReceipt>(options.failureOrNull!);
      }

      lines.add(
        CustomerReceiptLine(
          name: item.itemNameSnapshot,
          variantName: item.variantNameSnapshot,
          quantity: item.quantity,
          unitPrice: item.unitPrice,
          lineTotal: item.totalAmount,
          notes: item.notes,
          options: options.valueOrNull!
              .map(
                (OrderItemOption option) => CustomerReceiptLineOption(
                  name: option.optionNameSnapshot,
                  price: option.price,
                  quantity: option.quantity,
                ),
              )
              .toList(growable: false),
        ),
      );
    }

    final BusinessIdentity business = await identity.load();
    final Customer? customer = await _customer(order.customerId);

    return Ok<CustomerReceipt>(
      CustomerReceipt(
        business: business,
        orderNumber: order.orderNumber,
        orderType: order.orderType,
        issuedAt: order.createdAt,
        lines: lines,
        totals: totals,
        // The first settled tender. Split payment is a later feature, and when it
        // arrives this is the line that changes.
        paymentMethod: settled.first.paymentMethod,
        customerName: order.customerName ?? customer?.name,
        customerPhone: customer?.phone,
        notes: order.notes,
        isReprint: isReprint,
      ),
    );
  }

  /// The customer's record, or `null` for a walk-in or an unreadable record.
  ///
  /// A failure here is deliberately swallowed. A receipt without the customer's phone
  /// number is a perfectly good receipt; refusing to print one because the customer
  /// table could not be read would be a poor trade at a counter.
  Future<Customer?> _customer(String? customerId) async {
    if (customerId == null) {
      return null;
    }
    final Result<Customer?> found = await customers.findById(customerId);
    return found.fold<Customer?>(
      onOk: (Customer? customer) => customer,
      onErr: (AppFailure _) => null,
    );
  }

  // ------------------------------------------------------------------- kot ---

  Future<Result<List<KitchenKot>>> _kots({
    required Order order,
    required bool isReprint,
  }) async {
    final Result<List<KitchenTicket>> tickets = await kots.loadTicketsForOrder(
      order.id,
    );
    if (tickets.isErr) {
      return Err<List<KitchenKot>>(tickets.failureOrNull!);
    }

    final Customer? customer = await _customer(order.customerId);

    return Ok<List<KitchenKot>>(
      tickets.valueOrNull!
          .map(
            (KitchenTicket ticket) => KitchenKot(
              kotNumber: ticket.kotNumber,
              orderNumber: ticket.orderNumber,
              orderType: ticket.orderType,
              issuedAt: ticket.createdAt,
              customerName: order.customerName ?? customer?.name,
              customerPhone: customer?.phone,
              notes: ticket.notes,
              isReprint: isReprint,
              lines: ticket.lines
                  .map(
                    (KitchenTicketLine line) => KitchenKotLine(
                      name: line.item.itemNameSnapshot,
                      variantName: line.item.variantNameSnapshot,
                      quantity: line.quantity,
                      notes: line.notes,
                      // Names only. The slip has nowhere to carry a price.
                      options: line.options
                          .map(
                            (KotItemOption option) => option.optionNameSnapshot,
                          )
                          .toList(growable: false),
                    ),
                  )
                  .toList(growable: false),
            ),
          )
          .toList(growable: false),
    );
  }
}
