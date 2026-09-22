import '../../domain/models/print_job.dart';
import 'escpos_thermal_printer.dart';
import 'transport/raw_print_transport.dart';

/// A real ESC/POS printer: [EscPosThermalPrinter] with a physical [RawPrintTransport]
/// underneath.
///
/// ## The concrete adapter the seam was built for
///
/// `EscPosThermalPrinter` leaves exactly three things to a transport adapter —
/// [openTransport], [closeTransport] and [writeToTransport] — and this class supplies
/// them by forwarding to a [RawPrintTransport]. Everything else (the connection state
/// machine, the document queue, the translation of a thrown transport error into a
/// `PrinterFailure`) is inherited unchanged.
///
/// The result is that a Mac talking to a USB printer through CUPS, a Windows terminal
/// talking to the print spooler, and either one talking to a network printer over a
/// socket are all *this same class*. Only the [RawPrintTransport] handed in differs, and
/// the transport is chosen once, by the platform factory, from the saved settings.
///
/// ## Why the transport is not the printer
///
/// A [RawPrintTransport] is a byte sink with no connection state and no queue. Keeping it
/// that small means the tricky, identical parts live in one place — the base class — and
/// each platform contributes only the few lines that genuinely differ. It is also what
/// makes a transport testable in isolation: a fake sink records bytes, and a fake that
/// throws exercises the failure path without a printer in the room.
class TransportThermalPrinter extends EscPosThermalPrinter {
  TransportThermalPrinter({
    required this._transport,
    required super.endpoint,
    super.capabilities,
    super.profile,
  });

  // The private field formal above exposes this to callers under the name `transport`.
  final RawPrintTransport _transport;

  /// The sink in use, for a diagnostic or a test that needs the concrete object.
  RawPrintTransport get transport => _transport;

  @override
  Future<void> openTransport() => _transport.open();

  @override
  Future<void> closeTransport() => _transport.close();

  @override
  Future<void> writeToTransport(PrintJob job) =>
      // The whole encoded document, handed over unchanged. The title travels only as a
      // label the spooler can show; it never touches the bytes.
      _transport.write(job.bytes, jobName: job.title);
}
