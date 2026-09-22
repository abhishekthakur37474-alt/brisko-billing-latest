import 'dart:io';

import '../../domain/models/printer_connection.dart';
import '../../domain/models/printer_connection_settings.dart';
import '../../domain/models/printer_status.dart';
import '../../domain/printers/thermal_printer_factory.dart';
import 'transport/cups_raw_print_transport.dart';
import 'transport/raw_print_transport.dart';
import 'transport/socket_raw_print_transport.dart';
import 'transport/windows_spooler_print_transport.dart';
import 'transport_thermal_printer.dart';
import 'unconfigured_thermal_printer.dart';

/// The one place a physical transport is chosen, from the saved settings and the
/// operating system this terminal is running on.
///
/// ## What it replaces, and what it does not
///
/// It is the production replacement for `NoTransportPrinterFactory`: where that returned
/// a printer that fails every send, this returns a real [TransportThermalPrinter] backed
/// by the transport appropriate to the platform and the configured connection. Everything
/// above `ThermalPrinterFactory` — billing, checkout, the print service, the screens — is
/// unchanged; swapping this factory in at the single bootstrap seam is the whole of the
/// hardware integration.
///
/// It still refuses to pretend. A connection this build cannot serve — a USB printer on
/// a platform with no USB path — resolves to an `UnconfiguredThermalPrinter` reporting
/// [PrinterTransportSupport.notInstalled], exactly as before. Nothing here reports a
/// transport as available unless a real adapter for it is constructed.
///
/// ## The mapping
///
/// * **Network (LAN / Wi-Fi)** — a TCP socket to the printer, on every platform. A
///   network printer needs no per-OS code.
/// * **USB on macOS** — the CUPS print system (`lp -o raw`) drives the USB port. macOS
///   does not let an application own a USB printer directly, and CUPS already can.
/// * **USB on Windows** — the Windows print spooler with the RAW datatype drives the
///   installed printer queue.
/// * **USB elsewhere** — not served; reported honestly as not installed.
class PlatformThermalPrinterFactory implements ThermalPrinterFactory {
  PlatformThermalPrinterFactory({
    PrinterHostPlatform? platform,
    RawPrintTransport Function(PrinterEndpoint endpoint)? lanTransport,
    RawPrintTransport Function(PrinterEndpoint endpoint)? macUsbTransport,
    RawPrintTransport Function(PrinterEndpoint endpoint)? windowsUsbTransport,
  }) : _platform = platform ?? PrinterHostPlatform.current(),
       _lanTransport = lanTransport ?? _defaultLanTransport,
       _macUsbTransport = macUsbTransport ?? _defaultMacUsbTransport,
       _windowsUsbTransport =
           windowsUsbTransport ?? _defaultWindowsUsbTransport;

  final PrinterHostPlatform _platform;
  final RawPrintTransport Function(PrinterEndpoint endpoint) _lanTransport;
  final RawPrintTransport Function(PrinterEndpoint endpoint) _macUsbTransport;
  final RawPrintTransport Function(PrinterEndpoint endpoint)
  _windowsUsbTransport;

  @override
  PrinterResolution create(PrinterConnectionSettings settings) {
    final PrinterEndpoint? endpoint = settings.endpoint;

    if (endpoint == null) {
      // Nothing described completely enough to open. Documents are still laid out for the
      // configured roll, so what is verified now is what prints once a printer is set up.
      return PrinterResolution(
        printer: UnconfiguredThermalPrinter(
          capabilities: settings.capabilities,
        ),
        support: PrinterTransportSupport.notConfigured,
      );
    }

    final RawPrintTransport? transport = _transportFor(endpoint);
    if (transport == null) {
      // The transport is understood but this build/platform has no adapter for it.
      return PrinterResolution(
        printer: UnconfiguredThermalPrinter(
          capabilities: settings.capabilities,
          configuredEndpoint: endpoint,
          reason: UnconfiguredThermalPrinter.transportMissing(
            transport: '${endpoint.transport.label} (${_platform.label})',
            printer: settings.description,
          ),
        ),
        support: PrinterTransportSupport.notInstalled,
      );
    }

    return PrinterResolution(
      printer: TransportThermalPrinter(
        transport: transport,
        endpoint: endpoint,
        capabilities: settings.capabilities,
      ),
      support: PrinterTransportSupport.available,
    );
  }

  /// The transport for [endpoint] on this platform, or null when none is served.
  RawPrintTransport? _transportFor(PrinterEndpoint endpoint) {
    switch (endpoint.transport) {
      case PrinterTransport.lan:
        // A socket works the same everywhere.
        return _lanTransport(endpoint);
      case PrinterTransport.usb:
        return switch (_platform) {
          PrinterHostPlatform.macos => _macUsbTransport(endpoint),
          PrinterHostPlatform.windows => _windowsUsbTransport(endpoint),
          PrinterHostPlatform.other => null,
        };
    }
  }

  // ------------------------------------------------------- default transports ---

  static RawPrintTransport _defaultLanTransport(PrinterEndpoint endpoint) =>
      SocketRawPrintTransport(
        host: endpoint.address ?? 'localhost',
        port: endpoint.port ?? PrinterEndpoint.defaultLanPort,
      );

  static RawPrintTransport _defaultMacUsbTransport(PrinterEndpoint endpoint) =>
      // deviceName is the CUPS raw queue name the operator added for the printer; null
      // falls back to the system default printer inside the transport.
      CupsRawPrintTransport(queueName: endpoint.deviceName);

  static RawPrintTransport _defaultWindowsUsbTransport(
    PrinterEndpoint endpoint,
  ) =>
      // deviceName is the Windows printer queue name.
      WindowsSpoolerPrintTransport(printerName: endpoint.deviceName ?? '');
}

/// Which operating system a terminal is running, reduced to the three cases the transport
/// choice actually turns on. Injected into the factory so platform resolution is testable
/// without the test having to be run on each OS.
enum PrinterHostPlatform {
  macos,
  windows,
  other;

  String get label => switch (this) {
    PrinterHostPlatform.macos => 'macOS',
    PrinterHostPlatform.windows => 'Windows',
    PrinterHostPlatform.other => 'this platform',
  };

  /// The platform this build is running on right now.
  static PrinterHostPlatform current() {
    if (Platform.isMacOS) {
      return PrinterHostPlatform.macos;
    }
    if (Platform.isWindows) {
      return PrinterHostPlatform.windows;
    }
    return PrinterHostPlatform.other;
  }
}
