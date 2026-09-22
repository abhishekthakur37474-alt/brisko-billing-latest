/// How a payment was tendered.
enum PaymentMethod {
  cash,

  /// Paid by scanning the UPI QR shown at the counter, or to the outlet's VPA.
  upi,

  card,

  /// Anything else, for example an aggregator settling an online order. The
  /// reference field on the payment records what it actually was.
  other;

  String get label => switch (this) {
    PaymentMethod.cash => 'Cash',
    PaymentMethod.upi => 'UPI',
    PaymentMethod.card => 'Card',
    PaymentMethod.other => 'Other',
  };

  /// True when the payment carries an external transaction reference worth
  /// recording.
  bool get expectsReference => this != PaymentMethod.cash;
}
