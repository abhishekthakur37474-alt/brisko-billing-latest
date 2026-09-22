import 'monochrome_bitmap.dart';

/// The outlet's own details, as they appear at the top of a receipt.
///
/// ## Nothing here is invented
///
/// Every field except [name] is nullable and is omitted from the printed document
/// when it is absent. The address, telephone number and GSTIN of a real business are
/// legal identifiers: a placeholder GSTIN on a tax invoice is worse than no GSTIN,
/// and an invented address is worse than a blank line. They are owned by the settings
/// module, entered once by the operator, and printed only once they exist.
///
/// [name] falls back to [defaultName] because the outlet name was given as part of
/// the requirement rather than left to configuration, and a receipt with no name at
/// all is not identifiable as a bill. It is still overridable from settings, which is
/// what a second outlet or a rename would need.
class BusinessIdentity {
  const BusinessIdentity({
    this.name = defaultName,
    this.address,
    this.phone,
    this.gstin,
    this.receiptHeader,
    this.receiptFooter,
    this.feedbackUrl,
    this.logo,
  });

  /// The outlet this build was written for.
  ///
  /// The only business fact with a default. Everything else must be configured.
  static const String defaultName = 'Brisko Pizza';

  /// An outlet that has configured nothing yet: a name and no claims.
  static const BusinessIdentity unconfigured = BusinessIdentity();

  final String name;

  /// Street address, printed under the name. Omitted when unset.
  final String? address;

  /// Contact number for the outlet, not the customer's. Omitted when unset.
  final String? phone;

  /// GST identification number. Legally required on a tax invoice, and printed only
  /// when the operator has entered the real one.
  final String? gstin;

  /// Extra line printed above the bill details, for example an outlet branch name.
  final String? receiptHeader;

  /// Closing line, for example a thank-you or a return policy.
  final String? receiptFooter;

  /// URL the feedback QR points at, so a customer can leave a review. Omitted when
  /// unset: a QR pointing nowhere is worse than an absent one.
  final String? feedbackUrl;

  /// The outlet's logo, already reduced to printable dots, or `null` when there is
  /// none to print.
  ///
  /// Optional the same way every other identity field is: an outlet that has not
  /// supplied a logo prints a header with just its name, rather than a placeholder
  /// image. The reduction from a source image to one bit per dot happens above the
  /// printing layer, where an image codec is available; this field is the finished
  /// result.
  final MonochromeBitmap? logo;

  bool get hasLogo => logo != null && !logo!.isEmpty;

  bool get hasAddress => _isPresent(address);

  bool get hasPhone => _isPresent(phone);

  bool get hasGstin => _isPresent(gstin);

  bool get hasReceiptHeader => _isPresent(receiptHeader);

  bool get hasReceiptFooter => _isPresent(receiptFooter);

  bool get hasFeedbackUrl => _isPresent(feedbackUrl);

  /// True when the operator has supplied everything a tax invoice needs.
  ///
  /// Not enforced at print time: refusing to print a bill because a setting is blank
  /// would stop the outlet trading. Surfaced so the settings screen can say what is
  /// still missing.
  bool get isCompleteForTaxInvoice => hasAddress && hasGstin;

  static bool _isPresent(String? value) =>
      value != null && value.trim().isNotEmpty;
}
