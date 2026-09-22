import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer_factory.dart';

/// A transport factory that always hands back the printer it was given.
///
/// This is the seam standing in for the USB or network adapter that has not been written
/// yet. It is what lets every test above the transport — job creation, the queue, the
/// failure message, the retry, the reprint, the test page — run against a printer whose
/// behaviour the test controls, through exactly the interface a real adapter will
/// implement.
///
/// It reports [PrinterTransportSupport.available], because for the purposes of the test
/// the transport genuinely is: a `FakeEscPosPrinter` extends the production
/// `EscPosThermalPrinter` and exercises its real connection state machine and its real
/// translation of a thrown transport error into a `PrinterFailure`. Nothing here fakes a
/// successful *write*; whether a send succeeds is the printer's decision, and
/// `FakeEscPosPrinter.failOnWrite` is how a test makes it fail.
class FixedPrinterFactory implements ThermalPrinterFactory {
  const FixedPrinterFactory(this.printer, {this.support = _available});

  static const PrinterTransportSupport _available =
      PrinterTransportSupport.available;

  final ThermalPrinter printer;

  /// What the factory claims about the transport. Overridden by a test that needs the
  /// "configured but this build cannot reach it" path with a printer of its own.
  final PrinterTransportSupport support;

  /// How many times a printer has been asked for.
  ///
  /// Not counted: the same printer is returned every time, so there is nothing a count
  /// would distinguish. A test that needs to observe rebinding asserts on
  /// `ConfigurableThermalPrinter.connectionSettings` instead, which is the thing that
  /// actually changed.
  @override
  PrinterResolution create(PrinterConnectionSettings settings) =>
      PrinterResolution(printer: printer, support: support);
}
