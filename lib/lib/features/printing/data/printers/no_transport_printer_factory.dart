import '../../domain/models/printer_connection.dart';
import '../../domain/models/printer_connection_settings.dart';
import '../../domain/models/printer_status.dart';
import '../../domain/printers/thermal_printer_factory.dart';
import 'unconfigured_thermal_printer.dart';

/// The transports this build ships, which are none.
///
/// ## Why this class exists rather than a `TODO`
///
/// The 80mm ESC/POS printer has been chosen and not yet bought. Writing a USB adapter
/// today would mean picking a package and a device-enumeration strategy against hardware
/// nobody has plugged in, and the first real device would very likely invalidate both.
/// What is worth building before the hardware arrives is the seam, and the seam is only
/// real if something implements it.
///
/// So this is the production factory: it accepts a complete, valid printer
/// configuration, records it, lays documents out for the roll it names, and then reports
/// truthfully that it cannot send them anywhere. Every part of the workflow above it —
/// job creation, the queue, the failure message, the retry, the reprint, the guarantee
/// that a settled bill stays settled — therefore runs in production from today.
///
/// ## What replaces it
///
/// One class, of a few dozen lines, per transport:
///
/// ```dart
/// class UsbEscPosPrinter extends EscPosThermalPrinter { /* three overrides */ }
/// ```
///
/// and then a factory that returns it for [PrinterTransport.usb] with
/// [PrinterTransportSupport.available]. `EscPosThermalPrinter` already owns the
/// connection state machine, the serialisation of documents and the translation of a
/// thrown transport error into a `PrinterFailure`, so an adapter supplies only
/// `openTransport`, `closeTransport` and `writeToTransport`. Nothing above
/// [ThermalPrinterFactory] changes.
///
/// ## It never fakes a success
///
/// Every printer it returns fails every send. That is the point: a stub that reported
/// success would make the screens, the tests and the operator all agree that printing
/// works, and the first real bill would be the thing that disagreed.
class NoTransportPrinterFactory implements ThermalPrinterFactory {
  const NoTransportPrinterFactory();

  @override
  PrinterResolution create(PrinterConnectionSettings settings) {
    // Documents are laid out for the configured roll either way. That is what makes the
    // receipt verified today the one that prints unchanged on the real device: only the
    // transport is missing, never the layout.
    final PrinterEndpoint? endpoint = settings.endpoint;

    if (endpoint == null) {
      return PrinterResolution(
        printer: UnconfiguredThermalPrinter(
          capabilities: settings.capabilities,
        ),
        support: PrinterTransportSupport.notConfigured,
      );
    }

    return PrinterResolution(
      printer: UnconfiguredThermalPrinter(
        capabilities: settings.capabilities,
        configuredEndpoint: endpoint,
        reason: UnconfiguredThermalPrinter.transportMissing(
          transport: endpoint.transport.label,
          printer: settings.description,
        ),
      ),
      support: PrinterTransportSupport.notInstalled,
    );
  }
}
