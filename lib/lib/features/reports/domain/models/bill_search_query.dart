import '../../../orders/domain/models/order_type.dart';
import 'date_range.dart';

/// What the cashier is looking for when they search the order history.
///
/// ## Why a value object rather than four parameters
///
/// The four criteria are answered together — a search is "these dates, this number, this
/// phone, this order type", any of which may be left out — and passing them as one object
/// keeps the repository signature stable if a fifth is ever added. It also gives the
/// controller one thing to hold and the tests one thing to build.
///
/// ## What "empty" means
///
/// Every field is optional. A query with nothing set is [isEmpty], and the controller reads
/// that as "show the recent bills" rather than running a search with no filter — the two
/// are different questions and a blank search box should not be treated as a filter that
/// matches everything.
///
/// ## What it does not decide
///
/// Which bills count as history. That is the repository's rule: a searched bill is a
/// settled one, exactly as a reported bill is. This object only narrows that set.
class BillSearchQuery {
  const BillSearchQuery({
    this.orderNumber,
    this.customerPhone,
    this.range,
    this.orderType,
  });

  /// A query that matches nothing in particular, so the recent bills are shown.
  static const BillSearchQuery none = BillSearchQuery();

  /// All or part of a bill number, matched anywhere in it. `null` or blank when not
  /// searched on.
  final String? orderNumber;

  /// All or part of a customer's phone number, matched anywhere in it. A search on this
  /// deliberately excludes walk-in bills, which have no number to match.
  final String? customerPhone;

  /// The days to search within, or `null` for no date limit.
  final DateRange? range;

  /// The kind of order to search for, or `null` for any.
  final OrderType? orderType;

  /// The bill number to match, trimmed, or `null` when nothing usable was entered.
  String? get orderNumberTerm => _clean(orderNumber);

  /// The phone digits to match, trimmed, or `null` when nothing usable was entered.
  String? get customerPhoneTerm => _clean(customerPhone);

  bool get hasOrderNumber => orderNumberTerm != null;

  bool get hasCustomerPhone => customerPhoneTerm != null;

  bool get hasRange => range != null;

  bool get hasOrderType => orderType != null;

  /// True when nothing has been asked for.
  bool get isEmpty =>
      !hasOrderNumber && !hasCustomerPhone && !hasRange && !hasOrderType;

  BillSearchQuery copyWith({
    String? orderNumber,
    String? customerPhone,
    DateRange? range,
    OrderType? orderType,
    bool clearRange = false,
    bool clearOrderType = false,
  }) {
    return BillSearchQuery(
      orderNumber: orderNumber ?? this.orderNumber,
      customerPhone: customerPhone ?? this.customerPhone,
      range: clearRange ? null : (range ?? this.range),
      orderType: clearOrderType ? null : (orderType ?? this.orderType),
    );
  }

  static String? _clean(String? value) {
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
