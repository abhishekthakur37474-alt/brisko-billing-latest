import 'dart:typed_data';

/// A one-way sink for an already-encoded ESC/POS document.
///
/// ## What it is, and where it sits
///
/// This is the physical half of the printing seam. Above it, `EscPosThermalPrinter`
/// owns everything that is identical for every ESC/POS printer — the connection state
/// machine, the one-document-at-a-time queue, and turning a thrown transport error into
/// a `PrinterFailure`. Below it, an implementation of this interface does the one thing
/// that actually differs between a Mac, a Windows terminal and a network printer: it
/// moves the bytes.
///
/// A [RawPrintTransport] is deliberately smaller than a `ThermalPrinter`. It has no
/// notion of a print job, a document, a paper width or a column count. It receives a
/// finished byte stream and hands it, unchanged, to the operating system's print
/// spooler or to a socket. That narrowness is the point: a transport that could not
/// reformat a bill cannot accidentally change one, and the same encoded stream verified
/// in a test is the stream that reaches the paper.
///
/// ## Failure is a throw here, a value above
///
/// Every method throws on failure. This mirrors how the underlying platform APIs behave
/// — `Process` exits non-zero, a `Socket` connection times out, `WritePrinter` returns
/// false — and it is `EscPosThermalPrinter` that catches the throw and translates it
/// into the single `PrinterFailure` the cashier reads. No transport has to get the
/// wording or the failure type right.
///
/// ## No fake success
///
/// An implementation must throw when the platform reports the bytes were not accepted.
/// Reporting success for bytes that were merely generated — never handed to a spooler,
/// or handed to a queue the operating system has disabled because the printer is
/// unplugged — is the one thing this interface exists to make impossible.
abstract interface class RawPrintTransport {
  /// How this destination should be named to the operator, for a log line or an error.
  String get description;

  /// Opens the connection to the device or spooler. Throws on failure.
  ///
  /// For a socket this dials the host; for a spooler queue it validates that the queue
  /// exists and is accepting work. Called before the first write, and again only after a
  /// [close].
  Future<void> open();

  /// Writes [bytes] verbatim. Throws on failure.
  ///
  /// [bytes] is a complete encoded document. An implementation may chunk it — a USB bulk
  /// endpoint has a maximum packet size, a socket has a send buffer — but must not
  /// reorder, drop or add to it. [jobName] is a human label the spooler can show beside
  /// the job; it never changes what is printed.
  Future<void> write(Uint8List bytes, {required String jobName});

  /// Releases the socket or the spooler handle. Throws on failure.
  Future<void> close();
}
