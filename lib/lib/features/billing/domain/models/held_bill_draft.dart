import '../../../../core/utils/entity_id.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/domain/models/order_type.dart';
import 'cart.dart';
import 'held_bill.dart';
import 'held_bill_status.dart';

/// Everything needed to put a bill aside, frozen before the write starts.
///
/// ## Why a draft rather than passing the cart
///
/// The same reason `BillSettlement` exists. The identity of the held bill is decided
/// here, once, before anything touches the database. So a hold that is submitted twice
/// — a double tap, or two terminals racing — carries the same [id] both times, and the
/// repository can refuse the second rather than quietly writing a second copy of the
/// same cart. A caller that handed over a bare cart would get a new id on every attempt,
/// and duplicates would be indistinguishable from two genuinely different held bills.
///
/// ## What it does not decide
///
/// The row ids of the lines and their options. Those are allocated by the repository
/// inside the write transaction, which is safe precisely because the header id is not:
/// a hold either commits whole or rolls back to nothing, and a retry is stopped at the
/// header before a line is written. See `SqliteHeldBillRepository`.
///
/// ## Money
///
/// No amount is constructed here. The prices are the ones already on the cart lines,
/// copied off the menu when each line was added.
class HeldBillDraft {
  const HeldBillDraft({
    required this.id,
    required this.cart,
    required this.orderType,
    required this.heldAt,
    this.customerPhone,
    this.notes,
  });

  /// Freezes the current cart into a draft, allocating its identity.
  ///
  /// [customerPhone] is normalised to the stored ten digits, or dropped when what was
  /// entered is not a usable number — a held bill is not the place to refuse a sale over
  /// a half-typed number, and settlement asks for it properly. [notes] is trimmed, and
  /// an empty note becomes `null` rather than an empty string.
  factory HeldBillDraft.fromCart({
    required Cart cart,
    required OrderType orderType,
    String? customerPhone,
    String? notes,
    DateTime? at,
  }) {
    final String? trimmedNotes = notes?.trim();

    return HeldBillDraft._(
      id: EntityId.generate(prefix: 'hld'),
      cart: cart,
      orderType: orderType,
      customerPhone: customerPhone == null
          ? null
          : CustomerPhone.tryNormalise(customerPhone),
      notes: trimmedNotes == null || trimmedNotes.isEmpty ? null : trimmedNotes,
      at: at,
    );
  }

  /// Named so the generative constructor stays the only place fields are assigned,
  /// while the factory can still default the instant.
  ///
  /// Redirects to the generative constructor, defaulting [at] to now in UTC so the
  /// factory does not have to. The instant is the one thing a draft is allowed to
  /// decide for itself; everything else is handed to it.
  HeldBillDraft._({
    required String id,
    required Cart cart,
    required OrderType orderType,
    required String? customerPhone,
    required String? notes,
    DateTime? at,
  }) : this(
         id: id,
         cart: cart,
         orderType: orderType,
         customerPhone: customerPhone,
         notes: notes,
         heldAt: at?.toUtc() ?? DateTime.now().toUtc(),
       );

  /// Identity of the held bill, fixed at construction. See the class doc.
  final String id;

  /// The cart being put aside.
  final Cart cart;

  final OrderType orderType;

  /// The stored form of the customer's number, or `null`.
  final String? customerPhone;

  final String? notes;

  /// When the bill was put aside. Stored UTC.
  final DateTime heldAt;

  /// True when there is anything worth holding.
  ///
  /// The repository refuses a draft without lines. An empty held bill would show up in
  /// the list as something to resume and give the cashier an empty cart back.
  bool get hasLines => cart.isNotEmpty;

  /// The record to write, at [HeldBillStatus.held].
  HeldBill toHeldBill() {
    return HeldBill(
      id: id,
      cart: cart,
      orderType: orderType,
      customerPhone: customerPhone,
      notes: notes,
      status: HeldBillStatus.held,
      heldAt: heldAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  String toString() =>
      'HeldBillDraft($id, ${cart.lineCount} lines, ${orderType.name})';
}
