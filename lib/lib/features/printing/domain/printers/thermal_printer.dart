import '../../../../core/utils/result.dart';
import '../models/print_job.dart';
import '../models/print_profile.dart';
import '../models/printer_capabilities.dart';
import '../models/printer_connection.dart';

/// A thermal receipt printer.
///
/// ## What this abstraction buys
///
/// The outlet has chosen an 80mm ESC/POS printer with USB and Ethernet, but it has not
/// been bought. Everything above this interface — billing, checkout, the kitchen slip
/// and the documents themselves — is written against these seven members and learns
/// nothing about ESC/POS, byte streams, USB descriptors or socket timeouts. When the
/// hardware arrives, a transport adapter is added underneath and none of that code
/// changes.
///
/// It is also what makes printing testable with no printer in the room: a test supplies
/// its own implementation that keeps the jobs in memory, and can be told to fail on
/// demand, which is the only way to exercise the "paid but not printed" path
/// deliberately.
///
/// ## A printer receives jobs, not documents
///
/// [send] takes a [PrintJob], which is already encoded. A printer here is a transport
/// with a connection state: it moves bytes and reports whether they were accepted. It
/// does not lay out a receipt, does not know what a bill is, and cannot change what is
/// printed. That is why a retry is safe by construction — the job it re-sends is the job
/// that was built from the committed sale.
///
/// ## No Flutter, no widgets
///
/// This library is plain Dart. A printer is not part of the widget tree, and a
/// document is not built during a frame.
///
/// ## Failure is a value
///
/// Nothing here throws. A printer that is unplugged mid-bill is an ordinary
/// operational event at a counter, not an exceptional one, so every method returns a
/// `Result` and the caller is forced to decide what the cashier is told. In particular
/// a failure from [send] must never be allowed to undo a settled sale.
abstract interface class ThermalPrinter {
  /// Where the printer stands right now.
  PrinterConnectionState get connectionState;

  /// State changes, for a screen showing a connection indicator.
  ///
  /// Broadcast, so more than one screen can watch. Emits the current state on
  /// listen, so a widget built after a change does not sit on a stale value.
  Stream<PrinterConnectionState> get connectionStates;

  /// Where this printer is, or `null` when none has been configured.
  PrinterEndpoint? get endpoint;

  /// What the printer can physically do, including its paper width.
  PrinterCapabilities get capabilities;

  /// The layout every document for this printer must be encoded for.
  ///
  /// Derived from [capabilities], so the two cannot disagree. Exposed because the code
  /// that builds documents has to encode them for *this* printer: it is read once when
  /// the encoder is constructed, and never consulted per document.
  PrintProfile get profile;

  /// Opens the connection.
  ///
  /// Idempotent: calling it while already connected succeeds without reopening, so
  /// the print path can call it defensively before every document rather than
  /// tracking cable state itself.
  Future<Result<void>> connect();

  /// Closes the connection, releasing the USB handle or the socket.
  ///
  /// Succeeds when already disconnected. A printer is not left open between bills on
  /// a shared network port, because a second terminal would be refused.
  Future<Result<void>> disconnect();

  /// Sends [job] to the printer.
  ///
  /// Connects first if needed. Returns a failure, never a throw, when the printer is
  /// absent, unreachable, out of paper or reports an error. On failure nothing about
  /// the sale changes: the same job can be sent again unchanged, and doing so produces
  /// another piece of paper and nothing else.
  Future<Result<void>> send(PrintJob job);

  /// Releases the connection and the state stream.
  Future<void> dispose();
}
