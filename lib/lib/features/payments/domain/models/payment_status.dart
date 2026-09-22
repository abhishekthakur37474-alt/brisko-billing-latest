/// Whether a tendered payment actually landed.
///
/// Needed because UPI and card are not instantaneous: the cashier records the
/// attempt, then confirms it. Cash is recorded as [completed] immediately.
enum PaymentStatus {
  /// Recorded but not yet confirmed, for example a UPI QR shown and awaiting
  /// confirmation.
  pending,

  completed,

  failed,

  /// Reversed after completion.
  refunded;

  String get label => switch (this) {
    PaymentStatus.pending => 'Pending',
    PaymentStatus.completed => 'Completed',
    PaymentStatus.failed => 'Failed',
    PaymentStatus.refunded => 'Refunded',
  };

  /// True when this payment should count towards the amount collected.
  bool get isSettled => this == PaymentStatus.completed;
}
