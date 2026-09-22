/// Where a kitchen slip stands.
///
/// ## Preparation, not payment
///
/// These states describe food, never money. A bill is settled the moment the
/// cashier takes the payment, and that fact is recorded on the order and its
/// payment rows. The slip then moves through preparation on its own, so a paid
/// order whose food is still in the oven is not misreported as unfinished, and a
/// slip that reaches [ready] does not claim anything about whether it was paid for.
///
/// ## The local workflow
///
/// [pending] -> [preparing] -> [ready], and nothing else. The outlet has one
/// terminal and no kitchen screen, so whoever is at the till advances the slip when
/// the kitchen tells them. Movement is forward only: a slip that has been cooked
/// cannot become uncooked, and letting the state go backwards would only ever hide
/// a mistake rather than correct one.
///
/// [completed] and [cancelled] are the terminal states an order-level action will
/// set. Neither is reachable from the kitchen board.
///
/// ## Why printing does not move a slip
///
/// [printed] exists in this vocabulary and the printing module deliberately never
/// sets it. It is not [isActive], so writing it when a slip came out of the printer
/// would take that slip off the kitchen board — at the exact moment the paper reached
/// the pass and the food had not been started. On an outlet with one printer and no
/// kitchen screen, the board *is* the kitchen's list of outstanding work, and paper is
/// a copy of it rather than a replacement for it.
///
/// So printing reads kitchen tickets and writes none. A slip can be reprinted any
/// number of times without moving, which is also what makes a reprint safe: there is
/// no code path from the printer back into these rows. See `PrintService`.
enum KotStatus {
  /// Raised and waiting. The kitchen has not started on it.
  pending,

  /// Being cooked.
  preparing,

  /// Cooked and waiting to be handed over.
  ready,

  /// A paper slip was produced on the shared thermal printer.
  ///
  /// Never set by this build. Printing a slip does not change where it stands in the
  /// kitchen, and moving it here would take it off the board. See the note above.
  printed,

  completed,

  cancelled;

  String get label => switch (this) {
    KotStatus.pending => 'Pending',
    KotStatus.preparing => 'Preparing',
    KotStatus.ready => 'Ready',
    KotStatus.printed => 'Printed',
    KotStatus.completed => 'Completed',
    KotStatus.cancelled => 'Cancelled',
  };

  /// True when the slip still needs to reach the kitchen on paper.
  bool get needsPrinting => this == KotStatus.pending;

  /// True when the slip belongs on the kitchen board.
  ///
  /// The board shows work that is outstanding. A completed or cancelled slip is
  /// history, and a printed one is the printing module's business.
  bool get isActive =>
      this == KotStatus.pending ||
      this == KotStatus.preparing ||
      this == KotStatus.ready;

  /// The one state the kitchen may move this slip to, or `null` at the end of the
  /// workflow.
  KotStatus? get nextStep => switch (this) {
    KotStatus.pending => KotStatus.preparing,
    KotStatus.preparing => KotStatus.ready,
    KotStatus.ready => null,
    KotStatus.printed => null,
    KotStatus.completed => null,
    KotStatus.cancelled => null,
  };

  /// True when [next] is the legal forward move from here.
  ///
  /// Deliberately strict: staying put, skipping a state and going backwards are all
  /// false, so the repository can refuse anything that is not the single move the
  /// board offers.
  bool canAdvanceTo(KotStatus next) => nextStep == next;

  /// Wording for the button that performs [nextStep], or `null` when there is none.
  String? get advanceLabel => switch (nextStep) {
    KotStatus.preparing => 'Start preparing',
    KotStatus.ready => 'Mark ready',
    _ => null,
  };
}
