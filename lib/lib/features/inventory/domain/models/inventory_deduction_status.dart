/// How a settled bill's stock deduction ended.
///
/// Only two outcomes, and deliberately so. Deduction is all-or-nothing: it either took
/// every ingredient every configured recipe called for, or it took none of them. There
/// is no partial state, because a bill that had taken half its cheese and none of its
/// flour would leave two balances wrong in opposite directions with nothing to say
/// which.
enum InventoryDeductionStatus {
  /// Every configured recipe on the bill has been taken off the shelf.
  ///
  /// Terminal. A bill in this state is never deducted again, however many times it is
  /// retried, which is what makes the operation idempotent.
  ///
  /// A bill whose lines had no recipes at all also ends here, with nothing deducted
  /// and its unconfigured lines listed. That is the honest outcome: the bill has been
  /// processed, and what it could not deduct is recorded rather than pending.
  deducted,

  /// Nothing was deducted, and the balances are exactly as they were.
  ///
  /// Retryable. The usual cause is a shelf that does not hold what a recipe says it
  /// should, which the operator fixes by recording the stock that was actually
  /// received and retrying.
  ///
  /// The bill itself is unaffected and remains settled. The customer paid, the kitchen
  /// has its slip, and the sale is complete; what is outstanding is a stock figure.
  failed;

  String get label => switch (this) {
    InventoryDeductionStatus.deducted => 'Stock deducted',
    InventoryDeductionStatus.failed => 'Stock not deducted',
  };

  bool get isComplete => this == InventoryDeductionStatus.deducted;

  bool get isFailed => this == InventoryDeductionStatus.failed;
}
