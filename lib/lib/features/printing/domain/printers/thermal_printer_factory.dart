import '../models/printer_connection_settings.dart';
import '../models/printer_status.dart';
import 'thermal_printer.dart';

/// Turns saved printer settings into a printer.
///
/// ## The whole of the hardware requirement
///
/// This is the one place a transport is chosen. Everything above it — billing, checkout,
/// the kitchen slip, the print service, the screens — is written against
/// [ThermalPrinter] and cannot tell USB from a socket. Supporting the 80mm ESC/POS
/// printer the outlet buys means writing one adapter and returning it from one
/// implementation of this interface. Nothing else in the application changes.
///
/// ## Why a factory rather than a constructor call
///
/// The printer is not known at start-up in the way a repository is: it depends on rows in
/// the settings table, and it changes when the operator saves a different address. A
/// factory lets `ConfigurableThermalPrinter` rebuild its delegate on demand while the
/// print service keeps holding the same object, so a corrected address prints the next
/// bill rather than waiting for a restart.
///
/// ## It reports support, and does not pretend
///
/// [create] returns the printer *and* what happened. A build with no adapter for the
/// configured transport returns a printer that fails every send, together with
/// [PrinterTransportSupport.notInstalled], so the operator is told the software is
/// incomplete rather than being left to conclude the printer is faulty. Returning a
/// stub that reported success would make every screen and every test agree that printing
/// works right up until a real printer disagreed.
abstract interface class ThermalPrinterFactory {
  /// A printer for [settings], and whether its transport could be opened at all.
  ///
  /// Never throws and never returns null. A terminal always has a printer object, even
  /// when that object's honest answer to everything is "no printer here": a nullable
  /// printer would put a null check on every print path and leave that path unexercised
  /// until hardware arrived.
  PrinterResolution create(PrinterConnectionSettings settings);
}

/// A printer, and what its transport turned out to be.
class PrinterResolution {
  const PrinterResolution({required this.printer, required this.support});

  final ThermalPrinter printer;

  /// Whether [printer] can actually reach the configured device on this build.
  final PrinterTransportSupport support;

  @override
  String toString() => 'PrinterResolution(${support.name})';
}
