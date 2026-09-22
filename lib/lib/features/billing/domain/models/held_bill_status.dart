/// Where a held bill stands.
///
/// ## Three states, one of them open
///
/// A bill is [held] the moment it is put aside, and stays that way until someone
/// decides its fate: it is [resumed] back onto the counter, or [cancelled] and
/// abandoned. Both of those are terminal. A held bill is never reopened once it has
/// left [held], because a resumed bill has become the live cart and a cancelled one
/// was deliberately let go.
///
/// ## Availability is the only question the list asks
///
/// The held-bills list shows what a cashier can still act on, and that is exactly the
/// bills at [held]. [isAvailable] answers it in one place so the model, the summary and
/// the repository cannot disagree about which bills are still on the terminal.
///
/// The stored value is the enum's [name]. A value written by a newer build that this
/// one does not recognise is read back as [cancelled] rather than [held], so a bill this
/// build cannot account for is never offered to a cashier as resumable. See
/// `HeldBill.fromRow`.
enum HeldBillStatus {
  /// Put aside and waiting. The one state a bill can be resumed or cancelled from.
  held,

  /// Taken back onto the counter as the live cart. Terminal.
  resumed,

  /// Abandoned. Kept for audit rather than deleted, but no longer resumable. Terminal.
  cancelled;

  /// True while the bill is still there to be resumed or cancelled.
  ///
  /// Only [held] is available. [resumed] and [cancelled] are both closed, so the list
  /// and every guard treat them the same: nothing further can be done to the bill.
  bool get isAvailable => this == HeldBillStatus.held;
}
