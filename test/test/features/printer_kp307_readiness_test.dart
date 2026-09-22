import 'dart:typed_data';

import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/printing/data/printers/no_transport_printer_factory.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer_factory.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hardware-independent readiness checks for the incoming 80mm printer (KP307-UEWB).
///
/// ## What these do, and what they explicitly do NOT do
///
/// They lock the parts of the printing seam that the physical printer will rely on, and
/// that are decidable today without any hardware: how the printer's four interfaces map
/// onto the transports the application models, what a network printer defaults to when a
/// port is not typed, and — most importantly — that a fully-configured printer on this
/// build is reported as *not printable* rather than faked into looking like it works.
///
/// They do not verify the KP307-UEWB. No byte here has been sent to a real device, no
/// cut has been observed, and nothing below should be read as "hardware support is
/// verified". That verification can only happen with the printer plugged in, and is
/// deliberately out of scope until it arrives.
///
/// No manufacturer or model name appears in the application under test: the KP307-UEWB
/// is an ordinary 80mm ESC/POS printer with a cutter, a QR engine, and USB and network
/// interfaces, which is exactly the class the existing architecture already targets.
void main() {
  group('the KP307 interfaces map onto the transports the app models', () {
    // The KP307-UEWB offers USB, LAN, Wi-Fi and Bluetooth. The application models two
    // transports, and that is deliberate:
    //   * USB      -> PrinterTransport.usb  (a device on the bus)
    //   * LAN      -> PrinterTransport.lan  (a TCP socket to the printer)
    //   * Wi-Fi    -> PrinterTransport.lan  (the same TCP socket; a Wi-Fi printer is a
    //                                        network printer that happens to be wireless)
    //   * Bluetooth-> not modelled, on purpose: the printer sits on the counter beside
    //                 the terminal, so a wired or LAN link is preferred and Bluetooth
    //                 would add a failure mode for no benefit.
    // This test locks that mapping so a change to it has to be deliberate.
    test('exactly USB and network are modelled; Bluetooth is not', () {
      expect(
        PrinterTransport.values.map((PrinterTransport t) => t.name).toList(),
        <String>['usb', 'lan'],
      );
      expect(PrinterTransport.usb.isNetworked, isFalse);
      // A Wi-Fi KP307 is reached exactly as a wired-LAN one is: over the network.
      expect(PrinterTransport.lan.isNetworked, isTrue);
      expect(PrinterTransport.lan.label, 'Network');
    });
  });

  group('a network (LAN or Wi-Fi) printer defaults to the RAW port', () {
    // 9100 is the near-universal RAW/JetDirect port that ESC/POS network and Wi-Fi
    // printers listen on, which is what the KP307 will use. Leaving the port blank in
    // Settings must resolve to it, so the ordinary case needs no port typed at all.
    test('a blank port resolves to 9100 through the settings endpoint', () {
      const PrinterConnectionSettings wifi = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '192.168.1.50',
        port: null,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );

      expect(wifi.isConfigured, isTrue);
      final PrinterEndpoint endpoint = wifi.endpoint!;
      expect(endpoint.transport, PrinterTransport.lan);
      expect(endpoint.port, PrinterEndpoint.defaultLanPort);
      expect(endpoint.port, 9100);
      expect(endpoint.description, '192.168.1.50:9100');
    });

    test('the endpoint constructor itself defaults to 9100', () {
      const PrinterEndpoint endpoint = PrinterEndpoint.lan(host: '10.0.0.7');
      expect(endpoint.port, 9100);
      expect(endpoint.description, '10.0.0.7:9100');
    });

    test('an explicit port is kept as given', () {
      const PrinterConnectionSettings custom = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '192.168.1.50',
        port: 9101,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      expect(custom.endpoint!.port, 9101);
      expect(custom.endpoint!.description, '192.168.1.50:9101');
    });
  });

  group('the build does not fake success for a configured KP307', () {
    // The crux of "do not add fake physical printer success". The production factory
    // that ships in this build has no transport adapter, so a completely valid printer
    // configuration must still resolve to a printer that cannot print — and says so —
    // rather than one that silently pretends to.
    const NoTransportPrinterFactory factory = NoTransportPrinterFactory();

    Future<void> expectConfiguredButNotPrintable(
      PrinterConnectionSettings settings,
    ) async {
      expect(settings.isConfigured, isTrue);

      final PrinterResolution resolution = factory.create(settings);

      // The transport is understood but this build has no adapter for it.
      expect(resolution.support, PrinterTransportSupport.notInstalled);
      expect(
        resolution.printer.connectionState,
        PrinterConnectionState.unavailable,
      );

      // Opening it fails rather than succeeding quietly.
      final Result<void> opened = await resolution.printer.connect();
      expect(opened.isErr, isTrue);

      // And so does sending a document: no job is ever reported as printed.
      final PrintJob job = PrintJob(
        id: 'prj-readiness',
        kind: PrintJobKind.testPage,
        title: 'Readiness check',
        createdAt: DateTime.utc(2026),
        bytes: Uint8List.fromList(<int>[0x1B, 0x40]),
      );
      final Result<void> sent = await resolution.printer.send(job);
      expect(sent.isErr, isTrue);

      // Yet documents are still laid out for the real 80mm roll, so the receipt
      // verified today is the one that will print unchanged once a transport is added.
      expect(resolution.printer.profile.paper, PaperWidth.mm80);
      expect(resolution.printer.profile.columns, 48);
      expect(resolution.printer.profile.cut, PrintCut.full);
      expect(resolution.printer.capabilities.hasAutoCutter, isTrue);
      expect(resolution.printer.capabilities.supportsQrCode, isTrue);
    }

    test(
      'a USB KP307 is stored, laid out, and honestly not printable',
      () async {
        await expectConfiguredButNotPrintable(
          const PrinterConnectionSettings(
            isEnabled: true,
            transport: PrinterTransport.usb,
            address: null,
            port: null,
            deviceName: null,
            label: 'Counter printer',
            paperWidth: PaperWidth.mm80,
          ),
        );
      },
    );

    test(
      'a network KP307 is stored, laid out, and honestly not printable',
      () async {
        await expectConfiguredButNotPrintable(
          const PrinterConnectionSettings(
            isEnabled: true,
            transport: PrinterTransport.lan,
            address: '192.168.1.50',
            port: null,
            deviceName: null,
            label: 'Counter printer',
            paperWidth: PaperWidth.mm80,
          ),
        );
      },
    );
  });
}
