import '../../../../core/money/money.dart';
import '../../../billing/domain/models/gst_rate.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../payments/domain/models/payment_method.dart';
import 'business_identity.dart';

/// Something that can be printed.
///
/// ## Why print documents are their own models
///
/// A receipt is not an order and a kitchen slip is not a `KotRecord`. The domain
/// entities carry ids, sync state, soft-delete flags and foreign keys, none of which
/// belongs on paper, and they are shaped for storage rather than for a 48-column
/// layout. Printing from them directly would tie the paper layout to the schema, so
/// that adding a column meant reasoning about the receipt.
///
/// These documents are instead a flat, self-contained description of one piece of
/// paper: everything needed to render it and nothing else. They are built once from
/// persisted rows and are then independent of the database, which is what lets a
/// formatter be tested without one.
///
/// ## No Flutter
///
/// Nothing in this library imports `flutter`. A print document is not a widget tree
/// and a formatter is not a renderer; the whole printing layer is plain Dart, which is
/// why every test in it runs without a binding.
///
/// ## Why the family is sealed, and why it is one file
///
/// The set of documents is closed, so a formatter switching over it is exhaustive by
/// the compiler: adding a document type becomes a compile error at every formatter
/// rather than a blank page at the counter. Dart requires the subtypes of a sealed
/// type to live in the same library as the base, which is why the three documents and
/// their line types are declared here together rather than in a file each. They are
/// one concept — the paperwork this outlet produces — and the sealing is what makes
/// that concept enforceable.
sealed class PrintDocument {
  const PrintDocument();

  /// Short description used in a print job and in an operator-facing message, for
  /// example `Receipt 20260911-0001`.
  String get title;
}

// ------------------------------------------------------------------- receipt ---

/// The customer's bill, as one piece of 80mm paper.
///
/// Every amount is a [Money] in exact paise. Nothing on a receipt is a `double`: the
/// figures here are the ones already committed to the orders table, carried across
/// unchanged, so the paper and the database can never disagree by a paisa.
///
/// The lines are snapshots of what was sold, taken from the order rows rather than from
/// the menu, so reprinting this bill next month reproduces the original document.
final class CustomerReceipt extends PrintDocument {
  const CustomerReceipt({
    required this.business,
    required this.orderNumber,
    required this.orderType,
    required this.issuedAt,
    required this.lines,
    required this.totals,
    required this.paymentMethod,
    this.customerName,
    this.customerPhone,
    this.notes,
    this.isReprint = false,
  });

  /// Outlet details. Fields the operator has not configured are absent and are not
  /// printed.
  final BusinessIdentity business;

  /// Number the customer was given. The one thing they will quote back.
  final String orderNumber;

  final OrderType orderType;

  /// When the bill was settled, in UTC. Rendered in local time.
  final DateTime issuedAt;

  final List<CustomerReceiptLine> lines;

  final CustomerReceiptTotals totals;

  final PaymentMethod paymentMethod;

  /// Customer's name, when one was taken. Absent for a walk-in.
  final String? customerName;

  /// Customer's number, when one was taken. Absent for a walk-in.
  final String? customerPhone;

  /// Order-level note, printed under the lines.
  final String? notes;

  /// True when this is a second copy of a bill already given to the customer.
  ///
  /// Marked on the paper so a reprint cannot be mistaken for a second sale during a
  /// cash-up.
  final bool isReprint;

  @override
  String get title => 'Receipt $orderNumber';

  bool get hasCustomerName =>
      customerName != null && customerName!.trim().isNotEmpty;

  bool get hasCustomerPhone =>
      customerPhone != null && customerPhone!.trim().isNotEmpty;

  bool get hasNotes => notes != null && notes!.trim().isNotEmpty;

  /// Portions sold across every line, for the item count on the paper.
  int get totalQuantity => lines.fold<int>(
    0,
    (int running, CustomerReceiptLine line) => running + line.quantity,
  );
}

/// One charged line of a receipt.
class CustomerReceiptLine {
  const CustomerReceiptLine({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    this.variantName,
    this.options = const <CustomerReceiptLineOption>[],
    this.notes,
  });

  /// Product name as it was sold.
  final String name;

  /// Size as it was sold, or `null` for a single-price product.
  final String? variantName;

  final int quantity;

  /// Price of one unit as charged, including the chosen size and its options.
  final Money unitPrice;

  /// Amount charged for the line.
  final Money lineTotal;

  final List<CustomerReceiptLineOption> options;

  /// Preparation instruction, printed so the customer can see what they asked for.
  final String? notes;

  /// Name as it appears on paper, for example `Cheese Pizza (Medium)`.
  String get displayName => variantName == null ? name : '$name ($variantName)';

  bool get hasOptions => options.isNotEmpty;

  bool get hasNotes => notes != null && notes!.trim().isNotEmpty;
}

/// A customisation charged on a receipt line.
class CustomerReceiptLineOption {
  const CustomerReceiptLineOption({
    required this.name,
    required this.price,
    this.quantity = 1,
  });

  final String name;

  /// Price of one portion of this option, as charged.
  final Money price;

  final int quantity;

  /// What this option contributed to the line. Exact integer maths.
  Money get total => price * quantity;

  bool get isFree => price.isZero;
}

/// The money block at the foot of a receipt.
///
/// ## Every figure is carried, none is calculated
///
/// [subtotal], [discount], [tax] and [total] are the four amounts committed to the orders
/// table when the bill was settled, copied across unchanged. [taxRate] is the rate that
/// produced [tax], also as stored. Nothing here recomputes an amount from another one, so
/// a reprint next year cannot disagree with the paper the customer was given — not even by
/// a paisa, and not even if the outlet has changed slab since.
///
/// ## Which lines appear
///
/// Only the ones that describe a charge. A bill with no discount prints no discount line,
/// and a bill from an outlet charging no GST prints no tax lines: a row of zeroes invites
/// the customer to wonder what it is for, and a taxable-amount line that merely repeats the
/// subtotal above it says nothing.
///
/// The subtotal and the total are always printed, because those two are the bill.
///
/// ## CGST and SGST
///
/// [cgst] and [sgst] are halves of [tax], split by `Money.allocate` so they add back to it
/// exactly. They are a presentation of one authoritative figure, not two figures of their
/// own: applying half the rate twice would round twice, and a bill whose two tax lines do
/// not sum to the tax it charged is not defensible. There is no IGST, because the outlet is
/// one restaurant serving customers in its own state.
class CustomerReceiptTotals {
  const CustomerReceiptTotals({
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.total,
    this.taxRate = GstRate.zero,
    this.discountLabel,
  });

  final Money subtotal;

  final Money discount;

  final Money tax;

  /// Amount collected. Persisted as calculated at settlement time.
  final Money total;

  /// The rate [tax] was charged at, as recorded against this bill.
  ///
  /// Used only to label the tax lines. The amounts are stored figures and do not depend on
  /// it, so a bill whose rate was never recorded still prints its tax correctly — it just
  /// prints `GST` rather than `GST 18%`.
  final GstRate taxRate;

  /// How the discount was expressed, for example `10%` or `₹100.00`, or `null` when the
  /// rule was not recorded.
  ///
  /// A label beside a stored amount, never a calculation. A bill settled before the rule
  /// was persisted prints `Discount` with its amount and no explanation, which is what is
  /// known about it.
  final String? discountLabel;

  bool get hasDiscount => !discount.isZero;

  bool get hasTax => !tax.isZero;

  /// What the tax was charged on: [subtotal] less [discount].
  Money get taxableAmount => subtotal - discount;

  /// True when the taxable amount is worth a line of its own.
  ///
  /// Only when a discount moved it away from the subtotal and there is tax to explain.
  bool get showsTaxableAmount => hasDiscount && hasTax;

  /// The central half of the GST. [cgst] plus [sgst] is exactly [tax].
  Money get cgst => tax.allocate(2).first;

  /// The state half of the GST.
  Money get sgst => tax.allocate(2).last;

  /// True when subtotal minus discount plus tax is exactly the total.
  ///
  /// A bill whose block does not add up is worse than no bill, and because every figure
  /// is exact paise this can be checked rather than assumed. The document source
  /// refuses to build a receipt that fails it, so a formatter never has to decide what
  /// to do about one.
  bool get isConsistent => subtotal - discount + tax == total;
}

// ----------------------------------------------------------------------- kot ---

/// The kitchen slip, as one piece of 80mm paper.
///
/// ## No money
///
/// There is deliberately no price, no total and no payment method anywhere in this
/// document or its lines. The kitchen is being told what to cook; what it cost is the
/// counter's business, and a slip carrying prices invites the kitchen to be treated as
/// a second till. This is enforced by the type: there is no field to put an amount in,
/// so a formatter cannot print one by accident.
///
/// ## Snapshots
///
/// Every string here was copied from the order at the moment of sale. Nothing is read
/// from the menu, so reprinting a slip reproduces exactly what the kitchen was
/// originally asked for.
final class KitchenKot extends PrintDocument {
  const KitchenKot({
    required this.kotNumber,
    required this.orderNumber,
    required this.orderType,
    required this.issuedAt,
    required this.lines,
    this.customerName,
    this.customerPhone,
    this.notes,
    this.isReprint = false,
  });

  /// Number on the slip, so the counter and kitchen can refer to it aloud.
  final String kotNumber;

  /// Number the customer was given, so a slip can be matched to a bill.
  final String orderNumber;

  /// How the order leaves the counter. The kitchen plates a dine-in differently from a
  /// delivery.
  final OrderType orderType;

  /// When the slip was raised, in UTC. Rendered in local time.
  final DateTime issuedAt;

  final List<KitchenKotLine> lines;

  /// Customer's name, when one was taken. Absent for a walk-in.
  final String? customerName;

  /// Customer's number, when one was taken. Absent for a walk-in.
  final String? customerPhone;

  /// Order-level instruction, for example `no onion in anything`.
  final String? notes;

  /// True when the slip is being produced a second time.
  final bool isReprint;

  @override
  String get title => 'KOT $kotNumber';

  bool get hasCustomerName =>
      customerName != null && customerName!.trim().isNotEmpty;

  bool get hasCustomerPhone =>
      customerPhone != null && customerPhone!.trim().isNotEmpty;

  bool get hasNotes => notes != null && notes!.trim().isNotEmpty;

  /// Portions the kitchen has to make across every line.
  int get totalQuantity => lines.fold<int>(
    0,
    (int running, KitchenKotLine line) => running + line.quantity,
  );
}

/// One thing the kitchen has to make.
class KitchenKotLine {
  const KitchenKotLine({
    required this.name,
    required this.quantity,
    this.variantName,
    this.options = const <String>[],
    this.notes,
  });

  final String name;

  /// Size as it was sold, or `null` for a single-size product.
  final String? variantName;

  final int quantity;

  /// Customisation names, in the order they were added. Names only: an option's price
  /// is not the kitchen's business.
  final List<String> options;

  /// Preparation instruction on this line, for example `no onion`.
  final String? notes;

  /// Name as it appears on paper, for example `Cheese Pizza (Medium)`.
  String get displayName => variantName == null ? name : '$name ($variantName)';

  bool get hasOptions => options.isNotEmpty;

  bool get hasNotes => notes != null && notes!.trim().isNotEmpty;
}

// ----------------------------------------------------------------- test page ---

/// A short document that proves the printer works, without spending a bill on it.
///
/// Printed from the settings screen when a printer is first connected. It exercises the
/// parts of the path that go wrong in practice: the connection, the character width of
/// the paper, bold, alignment, the cutter, and the QR encoder.
///
/// The width ruler is the useful part. A line of 48 characters that arrives wrapped
/// means the printer is not the 80mm Font A device the layout assumes, which is exactly
/// the mistake that is otherwise discovered on a customer's bill.
final class PrinterTestPage extends PrintDocument {
  const PrinterTestPage({required this.printedAt, this.qrData});

  /// Data to encode into the sample QR, or `null` to omit it.
  ///
  /// Never a payment URI. A test page carrying a real `upi://pay` link could be scanned
  /// by a customer and take money against no order.
  final String? qrData;

  final DateTime printedAt;

  @override
  String get title => 'Printer test page';

  bool get hasQrData => qrData != null && qrData!.isNotEmpty;
}
