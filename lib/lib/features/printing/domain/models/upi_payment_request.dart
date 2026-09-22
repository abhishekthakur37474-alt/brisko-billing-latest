import '../../../../core/money/money.dart';

/// The data behind a UPI payment QR code.
///
/// ## What this is
///
/// A UPI QR is not an image the application invents; it is a `upi://pay` URI with the
/// payee's address, the payee's name and the amount. Modelling it as a value means the
/// QR on the receipt and the QR shown on screen are generated from the same fields,
/// and that the amount inside it is the exact [Money] on the bill rather than a
/// re-typed number.
///
/// ## Nothing is invented
///
/// [vpa] and [payeeName] come from settings. There is no default virtual payment
/// address, because a QR pointing at a made-up VPA would either fail in the
/// customer's app or, far worse, pay someone else. [forOrder] returns `null` when the
/// VPA has not been configured, and a receipt with no request simply prints no QR.
///
/// ## Amount
///
/// The `am` parameter is rendered from paise with [Money.toDecimalString], so it is
/// exact to two decimals and never passes through a floating point value.
class UpiPaymentRequest {
  const UpiPaymentRequest({
    required this.vpa,
    required this.payeeName,
    required this.amount,
    this.transactionNote,
    this.transactionReference,
  });

  /// Scheme and host of the deep link every UPI application understands.
  static const String scheme = 'upi';

  static const String host = 'pay';

  /// ISO currency code. UPI is rupees only, so this is fixed.
  static const String currency = 'INR';

  /// Builds a request, or returns `null` when the outlet has not configured a VPA.
  ///
  /// Returning null rather than throwing: an unconfigured UPI address is an ordinary
  /// state for a new terminal, and it must not stop a bill printing.
  static UpiPaymentRequest? forOrder({
    required String? vpa,
    required String? payeeName,
    required Money amount,
    String? orderNumber,
  }) {
    final String? address = _cleaned(vpa);
    if (address == null) {
      return null;
    }

    return UpiPaymentRequest(
      vpa: address,
      payeeName: _cleaned(payeeName) ?? address,
      amount: amount,
      transactionNote: orderNumber == null ? null : 'Order $orderNumber',
      transactionReference: _cleaned(orderNumber),
    );
  }

  /// The outlet's virtual payment address, for example `outlet@bank`.
  final String vpa;

  /// Name the customer sees in their UPI application before confirming.
  final String payeeName;

  /// Amount to collect. Exact paise.
  final Money amount;

  /// Free-text note shown to the customer, for example the order number.
  final String? transactionNote;

  /// Reference the outlet can reconcile against, usually the order number.
  final String? transactionReference;

  /// The `upi://pay?...` URI that goes into the QR code.
  ///
  /// Built through [Uri] so every value is percent-encoded. A payee name containing a
  /// space or an ampersand would otherwise produce a URI that some applications
  /// silently truncate.
  String toUri() {
    final Uri uri = Uri(
      scheme: scheme,
      host: host,
      queryParameters: <String, String>{
        'pa': vpa,
        'pn': payeeName,
        'am': amount.toDecimalString(),
        'cu': currency,
        'tn': ?transactionNote,
        'tr': ?transactionReference,
      },
    );
    return uri.toString();
  }

  static String? _cleaned(String? value) {
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() =>
      'UpiPaymentRequest($vpa, ${amount.toDecimalString()} $currency)';
}
