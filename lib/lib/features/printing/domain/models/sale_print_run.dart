import 'print_job.dart';

/// Everything that had to be printed for one sale, and how each part went.
///
/// A settled bill produces two documents on the same printer: the customer's receipt
/// and the kitchen slip. They can fail independently — the roll can run out between
/// them — so the outcome of a sale's printing is a set of jobs, not a boolean.
///
/// ## What this is not
///
/// It is not a record of the sale. The sale is the order, its lines, its payment and
/// its kitchen slip, all committed to the database before any of this runs. A run is a
/// transient, in-memory account of a printer's behaviour, held by the screen that is
/// showing it. If the terminal is restarted the run is gone and the sale is not.
class SalePrintRun {
  const SalePrintRun({
    required this.orderId,
    required this.orderNumber,
    required this.jobs,
  });

  /// What the cashier is told when the money is in but the paper is not out.
  ///
  /// Held here, as one string, because it is the single most important sentence in
  /// the printing layer. It must never read as though the payment failed.
  static const String paidButNotPrinted =
      'Payment successful, but printing failed.';

  /// The sale these jobs belong to.
  final String orderId;

  /// Number the customer was given, for the message on screen.
  final String orderNumber;

  final List<PrintJob> jobs;

  /// True when there was nothing to print.
  ///
  /// Not a failure. It is what a kitchen-slip reprint of an order that never raised a
  /// slip reports, and the difference matters: "there is no slip for this bill" and "the
  /// slip would not print" call for different things from whoever asked.
  bool get isEmpty => jobs.isEmpty;

  /// True when every document reached the printer.
  bool get isComplete =>
      jobs.isNotEmpty && jobs.every((PrintJob job) => job.isPrinted);

  bool get hasFailure => jobs.any((PrintJob job) => job.isFailed);

  bool get isInProgress => jobs.any((PrintJob job) => !job.state.isFinished);

  List<PrintJob> get failedJobs =>
      jobs.where((PrintJob job) => job.isFailed).toList(growable: false);

  List<PrintJob> get printedJobs =>
      jobs.where((PrintJob job) => job.isPrinted).toList(growable: false);

  /// Which documents still need paper, for example `Customer receipt, Kitchen slip`.
  String get failedDocuments =>
      failedJobs.map((PrintJob job) => job.kind.label).join(', ');

  /// The reason the printer gave, from the first failure. The same fault normally
  /// stops both documents, so repeating it twice would tell the cashier nothing.
  String? get failureReason =>
      failedJobs.isEmpty ? null : failedJobs.first.failureMessage;

  /// The whole message for the cashier, or `null` when there is nothing wrong.
  ///
  /// Leads with the fact that the money is safe, then names what did not print and
  /// why, because the cashier's first question is always whether to charge again.
  String? get operatorMessage {
    if (!hasFailure) {
      return null;
    }
    final String reason = failureReason ?? 'The printer did not respond.';
    return '$paidButNotPrinted $failedDocuments could not be printed. $reason';
  }

  /// Replaces the jobs, keeping the sale. Used as a run progresses.
  SalePrintRun withJobs(List<PrintJob> updated) =>
      SalePrintRun(orderId: orderId, orderNumber: orderNumber, jobs: updated);

  @override
  String toString() =>
      'SalePrintRun($orderNumber, ${printedJobs.length}/${jobs.length} printed)';
}
