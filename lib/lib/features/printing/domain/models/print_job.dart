import 'dart:typed_data';

/// What a print job was for.
enum PrintJobKind {
  customerReceipt,
  kitchenKot,
  testPage;

  String get label => switch (this) {
    PrintJobKind.customerReceipt => 'Customer receipt',
    PrintJobKind.kitchenKot => 'Kitchen slip',
    PrintJobKind.testPage => 'Test page',
  };
}

/// Where one attempt at printing stands.
///
/// ## Why this is not an order or payment status
///
/// A bill is settled when the money is taken, and that is recorded on the order and
/// the payment. Whether a piece of paper came out of a printer afterwards is a
/// completely separate fact, and conflating the two would be a serious modelling
/// error: a jammed printer would make a paid bill read as unpaid, a reprint would
/// look like a second sale, and a report of the day's takings would move whenever
/// someone changed a paper roll.
///
/// So printing has its own vocabulary, held here, and the order and payment rows are
/// never touched by it.
enum PrintJobState {
  /// Built and waiting for the printer.
  queued,

  /// Being written to the printer.
  printing,

  /// The printer accepted the whole document.
  ///
  /// Worth being precise about what this does and does not mean: ESC/POS is a
  /// one-way protocol over USB or a socket, so the strongest statement available is
  /// that the bytes were handed over without error. It is not a guarantee that paper
  /// came out.
  printed,

  /// The attempt failed and can be retried.
  failed;

  String get label => switch (this) {
    PrintJobState.queued => 'Waiting',
    PrintJobState.printing => 'Printing',
    PrintJobState.printed => 'Printed',
    PrintJobState.failed => 'Failed',
  };

  bool get isFinished =>
      this == PrintJobState.printed || this == PrintJobState.failed;
}

/// One encoded document, one printer, one outcome.
///
/// ## What it carries
///
/// [bytes] are the finished command stream: a complete document, already laid out for
/// the paper, ready to be handed to a transport unchanged. Everything else is the
/// metadata a counter needs when something goes wrong — what the document was, which
/// sale it belongs to, when it was built, how many times it has been sent, and what the
/// printer said last time.
///
/// This is the boundary the rest of the application works against. Billing, checkout and
/// the screens see a job with a title and a state; only the encoder below and the
/// transport above ever look at [bytes]. Nothing outside the printing feature needs to
/// know that ESC/POS exists.
///
/// ## Immutable
///
/// A change of state produces a new job through [copyWith], so a run can be held and
/// compared rather than mutated underneath the screen watching it. The byte list is
/// shared rather than copied between those states: it is never written to after the
/// encoder returns it, and copying a document per state change would be waste.
///
/// [attempts] counts how many times this document has been sent. It increments on a
/// retry, which is what lets the screen say "failed twice" rather than repeating the
/// same message, and it is the only thing a retry changes: retrying re-sends the same
/// document built from the same persisted rows, so it can never produce a second bill
/// or a second kitchen slip.
class PrintJob {
  const PrintJob({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    required this.bytes,
    this.state = PrintJobState.queued,
    this.orderId,
    this.attempts = 0,
    this.failureMessage,
  });

  final String id;

  final PrintJobKind kind;

  /// Description of the document, for example `Receipt 20260911-0001`.
  final String title;

  /// The sale this job belongs to, or `null` for a test page.
  final String? orderId;

  final DateTime createdAt;

  /// The encoded document, exactly as the printer will receive it.
  final Uint8List bytes;

  final PrintJobState state;

  /// How many times the document has been sent to a printer.
  final int attempts;

  /// Operator-facing reason the last attempt failed.
  final String? failureMessage;

  bool get isPrinted => state == PrintJobState.printed;

  bool get isFailed => state == PrintJobState.failed;

  /// True when this job is worth sending again.
  bool get canRetry => state == PrintJobState.failed;

  /// Size of the document, for a log line.
  int get byteCount => bytes.length;

  /// True when there is nothing to send. A document that encoded to nothing is a bug
  /// upstream, and sending it would silently produce a blank state rather than a fault.
  bool get isEmpty => bytes.isEmpty;

  /// A short, stable digest of [bytes], for logging and for comparing two jobs.
  ///
  /// FNV-1a, 32 bits, in integer arithmetic and masked to stay inside it. Not a
  /// cryptographic hash and not used as one: it exists so a log can record *which*
  /// document was sent, and so a retry can be shown to have re-sent the identical
  /// stream rather than a rebuilt-and-drifted one.
  String get fingerprint {
    int hash = 0x811C9DC5;
    for (final int byte in bytes) {
      hash = (hash ^ byte) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Marks the job as in flight and counts the attempt.
  PrintJob started() => copyWith(
    state: PrintJobState.printing,
    attempts: attempts + 1,
    clearFailure: true,
  );

  PrintJob succeeded() =>
      copyWith(state: PrintJobState.printed, clearFailure: true);

  PrintJob failedWith(String message) =>
      copyWith(state: PrintJobState.failed, failureMessage: message);

  /// The same job carrying a freshly encoded document.
  ///
  /// Used on a retry, which rebuilds the document from the persisted sale rather than
  /// replaying a cached stream. The job's identity, kind and attempt count are kept, so
  /// the retry is visibly the same job rather than a new one — which is what makes it
  /// impossible for a retry to look like a second sale.
  PrintJob withBytes(Uint8List encoded) => PrintJob(
    id: id,
    kind: kind,
    title: title,
    orderId: orderId,
    createdAt: createdAt,
    bytes: encoded,
    state: state,
    attempts: attempts,
    failureMessage: failureMessage,
  );

  PrintJob copyWith({
    PrintJobState? state,
    int? attempts,
    String? failureMessage,
    bool clearFailure = false,
  }) {
    return PrintJob(
      id: id,
      kind: kind,
      title: title,
      orderId: orderId,
      createdAt: createdAt,
      bytes: bytes,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      failureMessage: clearFailure
          ? null
          : failureMessage ?? this.failureMessage,
    );
  }

  @override
  String toString() =>
      'PrintJob($title, ${state.name}, attempts: $attempts, '
      '$byteCount bytes, $fingerprint)';
}
