import '../../../billing/domain/models/gst_rate.dart';
import '../../../orders/domain/models/order_type.dart';
import 'setting_keys.dart';

/// The outlet's own configuration: who it is, what its bills say, and how the till
/// behaves.
///
/// ## Why a typed value rather than a map
///
/// The settings table is key/value text, which is the right shape for storage — adding
/// a setting needs no migration — and the wrong shape for everything above it. A map
/// invites `stored['business.name']` at a dozen call sites, each with its own idea of
/// what a blank string means. This is the one place that decision is made: a key that
/// is absent, or holds nothing but whitespace, is `null`, and `null` means *not
/// configured*.
///
/// ## Nothing here is invented
///
/// Every business field is nullable and starts out null. There is no sample outlet
/// name, no placeholder address, no example GSTIN and no default UPI address, because
/// those are legal and financial identifiers belonging to the owner. A receipt omits
/// what has not been configured; it never prints a plausible-looking stand-in.
///
/// [defaultOrderType] is the one exception, and it is not business data: an order type
/// is one of four values this build already defines, and settlement has always had to
/// open on one of them.
///
/// ## No money, and a rate is not money
///
/// There is no amount and no discount on this class. Settings does not calculate money:
/// every figure on a bill is carried from the committed order, and nothing the operator
/// types here can change one.
///
/// [gstRate] is the one thing here that takes part in a calculation, and it is deliberately
/// not an amount: it is an integer count of basis points, it holds no paise, and it can only
/// reach a bill through `BillTotals`. It applies to bills settled *after* it is saved.
/// Changing it cannot move a bill that has already been issued, because settlement copies
/// the rate onto the order and nothing reads it back out of here afterwards.
class PosSettings {
  const PosSettings({
    this.businessName,
    this.businessAddress,
    this.businessPhone,
    this.gstin,
    this.receiptHeader,
    this.receiptFooter,
    this.feedbackUrl,
    this.upiVpa,
    this.upiPayeeName,
    this.defaultOrderType = fallbackOrderType,
    this.gstRate = GstRate.zero,
    this.printKitchenSlip = true,
    this.askCustomerDetails = true,
  });

  /// What is stored in the settings table, read into one value.
  ///
  /// A blank stored value reads the same as a missing row. That matters because clearing
  /// a field on the screen removes the row, and an older build may have written a blank
  /// one; both mean unconfigured.
  factory PosSettings.fromStored(Map<String, String?> stored) {
    return PosSettings(
      businessName: _text(stored[SettingKeys.businessName]),
      businessAddress: _text(stored[SettingKeys.businessAddress]),
      businessPhone: _text(stored[SettingKeys.businessPhone]),
      gstin: _text(stored[SettingKeys.gstin]),
      receiptHeader: _text(stored[SettingKeys.receiptHeader]),
      receiptFooter: _text(stored[SettingKeys.receiptFooter]),
      feedbackUrl: _text(stored[SettingKeys.feedbackUrl]),
      upiVpa: _text(stored[SettingKeys.upiVpa]),
      upiPayeeName: _text(stored[SettingKeys.upiPayeeName]),
      defaultOrderType:
          _orderType(stored[SettingKeys.defaultOrderType]) ?? fallbackOrderType,
      // Zero when the key is absent or holds something that is not a rate. An unreadable
      // rate must not become a guess: charging tax the outlet did not configure is worse
      // than charging none, and a missing key means an outlet that has not set one up.
      gstRate:
          GstRate.tryParseStored(stored[SettingKeys.gstRateBasisPoints]) ??
          GstRate.zero,
      printKitchenSlip: _flag(stored[SettingKeys.printKitchenSlip]) ?? true,
      askCustomerDetails: _flag(stored[SettingKeys.askCustomerDetails]) ?? true,
    );
  }

  /// A terminal that has configured nothing.
  ///
  /// What a freshly installed till holds, and what the Settings screen shows on the day
  /// it is opened for the first time.
  static const PosSettings unconfigured = PosSettings();

  /// The order type settlement opens on when none has been chosen.
  ///
  /// Takeaway, which is the value `CheckoutController` has always started on and the
  /// fallback `Order.fromRow` uses for an unreadable row. Named here so the Settings
  /// screen and the checkout flow cannot disagree about it.
  static const OrderType fallbackOrderType = OrderType.takeaway;

  /// The outlet's trading name, or `null` to print the build's own name.
  ///
  /// Optional because `BusinessIdentity` already falls back to `Brisko Pizza`: the
  /// outlet name was given as part of the requirement rather than left to
  /// configuration, and a bill with no name on it is not identifiable as a bill.
  final String? businessName;

  /// Street address, printed under the name. Omitted from the bill when null.
  final String? businessAddress;

  /// The outlet's own contact number.
  ///
  /// Stored as typed, apart from trimming. Deliberately **not** put through
  /// `CustomerPhone`: that rule is ten digits starting 6-9, because a customer's number
  /// is a lookup key and has to reduce to one form. An outlet's number is a line on a
  /// receipt and may legitimately be a landline with an STD code, so normalising it
  /// would refuse a real number, and silently rewriting it would print a number nobody
  /// can call.
  final String? businessPhone;

  /// GST identification number, validated by `Gstin` before it is stored.
  final String? gstin;

  /// Extra line printed above the bill details, for example a branch name.
  final String? receiptHeader;

  /// Closing line, for example a thank-you or a return policy.
  final String? receiptFooter;

  /// URL the paid receipt's feedback QR points at, so a customer can leave a review.
  ///
  /// No feedback QR is printed when this is null: a QR pointing at nothing is worse
  /// than an absent one.
  final String? feedbackUrl;

  /// UPI address the payment QR pays. No QR is printed when this is null.
  final String? upiVpa;

  /// Payee name shown in the customer's UPI application.
  final String? upiPayeeName;

  /// Order type the checkout flow opens on.
  final OrderType defaultOrderType;

  /// Combined GST rate applied to new bills. [GstRate.zero] until the outlet configures
  /// one, so an unconfigured terminal charges no tax and its bills are unchanged.
  ///
  /// Applies only to bills settled after it is saved. See the class comment.
  final GstRate gstRate;

  /// Whether a kitchen slip is sent to the printer after a sale.
  ///
  /// True until the owner turns it off. The slip is still written either way; this only
  /// decides whether paper comes out. An absent stored value reads as true, which is how
  /// the till has always behaved.
  final bool printKitchenSlip;

  /// Whether checkout asks for the customer's name and phone, and whether those
  /// details are printed on the customer bill.
  ///
  /// True until the owner turns it off. An absent stored value reads as true.
  final bool askCustomerDetails;

  /// These settings as rows for the settings table.
  ///
  /// A `null` value removes the key rather than storing an empty string, so "not
  /// configured" is one state in the table instead of two.
  Map<String, String?> toStored() => <String, String?>{
    SettingKeys.businessName: businessName,
    SettingKeys.businessAddress: businessAddress,
    SettingKeys.businessPhone: businessPhone,
    SettingKeys.gstin: gstin,
    SettingKeys.receiptHeader: receiptHeader,
    SettingKeys.receiptFooter: receiptFooter,
    SettingKeys.feedbackUrl: feedbackUrl,
    SettingKeys.upiVpa: upiVpa,
    SettingKeys.upiPayeeName: upiPayeeName,
    SettingKeys.defaultOrderType: defaultOrderType.name,
    // Always written, including zero. Unlike the text fields, absent and zero mean the same
    // thing here — no GST — so there is nothing to be gained by removing the row, and
    // writing it means the stored configuration states what the terminal is charging.
    SettingKeys.gstRateBasisPoints: gstRate.toStored(),
    SettingKeys.printKitchenSlip: printKitchenSlip ? 'true' : 'false',
    SettingKeys.askCustomerDetails: askCustomerDetails ? 'true' : 'false',
  };

  bool get hasBusinessName => businessName != null;

  bool get hasAddress => businessAddress != null;

  bool get hasPhone => businessPhone != null;

  bool get hasGstin => gstin != null;

  bool get hasReceiptHeader => receiptHeader != null;

  bool get hasReceiptFooter => receiptFooter != null;

  bool get hasFeedbackUrl => feedbackUrl != null;

  bool get hasUpiVpa => upiVpa != null;

  /// True when new bills carry a GST line.
  bool get chargesGst => gstRate.isCharged;

  /// True when the outlet has entered what a tax invoice needs.
  ///
  /// Not enforced anywhere: refusing to print a bill because a setting is blank would
  /// stop the outlet trading. Surfaced so the Settings screen can say what is missing.
  bool get isCompleteForTaxInvoice => hasAddress && hasGstin;

  PosSettings copyWith({
    String? businessName,
    String? businessAddress,
    String? businessPhone,
    String? gstin,
    String? receiptHeader,
    String? receiptFooter,
    String? feedbackUrl,
    String? upiVpa,
    String? upiPayeeName,
    OrderType? defaultOrderType,
    GstRate? gstRate,
    bool? printKitchenSlip,
    bool? askCustomerDetails,
  }) {
    return PosSettings(
      businessName: businessName ?? this.businessName,
      businessAddress: businessAddress ?? this.businessAddress,
      businessPhone: businessPhone ?? this.businessPhone,
      gstin: gstin ?? this.gstin,
      receiptHeader: receiptHeader ?? this.receiptHeader,
      receiptFooter: receiptFooter ?? this.receiptFooter,
      feedbackUrl: feedbackUrl ?? this.feedbackUrl,
      upiVpa: upiVpa ?? this.upiVpa,
      upiPayeeName: upiPayeeName ?? this.upiPayeeName,
      defaultOrderType: defaultOrderType ?? this.defaultOrderType,
      gstRate: gstRate ?? this.gstRate,
      printKitchenSlip: printKitchenSlip ?? this.printKitchenSlip,
      askCustomerDetails: askCustomerDetails ?? this.askCustomerDetails,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PosSettings &&
      other.businessName == businessName &&
      other.businessAddress == businessAddress &&
      other.businessPhone == businessPhone &&
      other.gstin == gstin &&
      other.receiptHeader == receiptHeader &&
      other.receiptFooter == receiptFooter &&
      other.feedbackUrl == feedbackUrl &&
      other.upiVpa == upiVpa &&
      other.upiPayeeName == upiPayeeName &&
      other.defaultOrderType == defaultOrderType &&
      other.gstRate == gstRate &&
      other.printKitchenSlip == printKitchenSlip &&
      other.askCustomerDetails == askCustomerDetails;

  @override
  int get hashCode => Object.hash(
    businessName,
    businessAddress,
    businessPhone,
    gstin,
    receiptHeader,
    receiptFooter,
    feedbackUrl,
    upiVpa,
    upiPayeeName,
    defaultOrderType,
    gstRate,
    printKitchenSlip,
    askCustomerDetails,
  );

  @override
  String toString() =>
      'PosSettings(name: ${businessName ?? 'unset'}, '
      'gstin: ${hasGstin ? 'set' : 'unset'}, '
      'gst: ${gstRate.label}, '
      'defaultOrderType: ${defaultOrderType.name}, '
      'printKitchenSlip: $printKitchenSlip, '
      'askCustomerDetails: $askCustomerDetails)';

  /// [stored] with its surrounding whitespace removed, or `null` when it holds nothing.
  ///
  /// Trimming is the only transformation applied to any text on this class. A receipt
  /// footer keeps its wording, its punctuation and its capitalisation exactly as the
  /// owner typed it.
  static String? _text(String? stored) {
    if (stored == null) {
      return null;
    }
    final String trimmed = stored.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The order type named by [stored], or `null` when it names none.
  ///
  /// Stored by enum name, so reordering `OrderType` cannot change a saved default, and
  /// an unrecognised name falls back rather than throwing.
  static OrderType? _orderType(String? stored) {
    if (stored == null) {
      return null;
    }
    for (final OrderType type in OrderType.values) {
      if (type.name == stored) {
        return type;
      }
    }
    return null;
  }

  /// [stored] as a flag. Anything other than the stored value `true` is false, which is
  /// the same reading `SettingsRepository.readBool` gives. Absent is left to the caller
  /// so each flag can keep its own default.
  static bool? _flag(String? stored) => stored == null ? null : stored == 'true';
}
