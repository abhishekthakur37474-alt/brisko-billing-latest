import 'dart:typed_data';

import 'package:brisko_billing/features/printing/data/printers/escpos_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';

/// A recording 80mm ESC/POS transport: an in-memory printer that keeps every job.
///
/// ## Why it extends the production printer
///
/// The obvious fake would implement `ThermalPrinter` from scratch. This deliberately
/// does not. It extends [EscPosThermalPrinter] and supplies only the three transport
/// methods a real adapter would, which means every test that prints through it also
/// exercises the production connection state machine, the document serialisation and the
/// failure-to-`PrinterFailure` translation.
///
/// It is also the proof of the seam the architecture claims: a USB or LAN adapter is
/// exactly this class with a real device or socket in place of [jobs]. If a transport
/// could not be added in thirty lines, this class could not exist either.
///
/// ## What it does and does not claim
///
/// It records that bytes were handed over. It does not pretend a printer was reached: no
/// paper exists, and a test asserting that a receipt "printed" is asserting only that the
/// application produced the right stream and the transport accepted it. That distinction
/// is the whole reason the real hardware still has to be verified in step 6B.
///
/// ## Test-only
///
/// Lives under `test/`, is not exported from `lib/`, and nothing in the application can
/// reach it. The production terminal has an `UnconfiguredThermalPrinter`, which reports
/// honestly that no printer is attached rather than pretending to print.
class FakeEscPosPrinter extends EscPosThermalPrinter {
  FakeEscPosPrinter({PrinterEndpoint? endpoint})
    : super(
        endpoint:
            endpoint ??
            const PrinterEndpoint.lan(host: '127.0.0.1', port: 9100),
      );

  /// Every job accepted, in order, exactly as it was handed over.
  final List<PrintJob> jobs = <PrintJob>[];

  /// States the printer passed through, for asserting the connection lifecycle.
  final List<PrinterConnectionState> observedStates =
      <PrinterConnectionState>[];

  int openCount = 0;
  int closeCount = 0;

  /// When true, opening the transport throws: the cable is out, or nothing is
  /// listening on the port.
  bool failOnOpen = false;

  /// When true, writing throws part way through: out of paper, or a jam.
  bool failOnWrite = false;

  /// What the simulated fault says. Surfaced as the `cause` of a `PrinterFailure`.
  String faultMessage = 'Out of paper.';

  /// The bytes of every job written, in order.
  ///
  /// Most assertions want the stream rather than the job around it, so this is what a
  /// transcript is read from.
  List<Uint8List> get documents =>
      jobs.map((PrintJob job) => job.bytes).toList(growable: false);

  /// The most recent document.
  Uint8List get lastDocument => documents.last;

  bool get hasPrinted => jobs.isNotEmpty;

  /// Jobs of one kind, for checking what reached the printer and what did not.
  List<PrintJob> jobsOf(PrintJobKind kind) =>
      jobs.where((PrintJob job) => job.kind == kind).toList(growable: false);

  /// Puts the printer back into working order, as reloading paper would.
  void repair() {
    failOnOpen = false;
    failOnWrite = false;
  }

  /// Forgets everything recorded, without changing the connection.
  void clearRecording() => jobs.clear();

  @override
  Future<void> openTransport() async {
    openCount++;
    observedStates.add(connectionState);
    if (failOnOpen) {
      throw FakePrinterTransportException(faultMessage);
    }
  }

  @override
  Future<void> closeTransport() async {
    closeCount++;
  }

  @override
  Future<void> writeToTransport(PrintJob job) async {
    observedStates.add(connectionState);
    if (failOnWrite) {
      // Thrown before recording, so a failed write leaves nothing behind. A real
      // printer that jams mid-document is worse than that, which is why a failure is
      // reported rather than assumed to have printed something usable.
      throw FakePrinterTransportException(faultMessage);
    }
    jobs.add(job);
  }
}

/// The kind of error a real transport throws: an unplugged cable, a closed socket, a
/// printer reporting no paper.
///
/// An `Exception` rather than an `Error`, because that is what it models: an
/// operational fault, not a bug. The printer base class is what turns it into a
/// `PrinterFailure`, which is the behaviour under test.
class FakePrinterTransportException implements Exception {
  const FakePrinterTransportException(this.message);

  final String message;

  @override
  String toString() => 'FakePrinterTransportException($message)';
}
