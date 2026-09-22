import 'dart:typed_data';

import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/printing/data/printers/platform_thermal_printer_factory.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/cups_raw_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/raw_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/socket_raw_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/windows_spooler_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport_thermal_printer.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer_factory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/recording_raw_transport.dart';

/// The platform factory is the one place a physical transport is chosen. These tests lock
/// that choice — which transport for which connection on which operating system — and the
/// honesty of the support it reports, without touching a real printer, socket or the
/// Win32 API. The transports themselves are verified by their own tests; here the
/// question is only which one the factory reaches for, and that a configuration it cannot
/// serve is reported as such rather than faked.
void main() {
  PrinterConnectionSettings usb({String? deviceName}) =>
      PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.usb,
        address: null,
        port: null,
        deviceName: deviceName,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );

  PrinterConnectionSettings lan({String host = '192.168.1.50', int? port}) =>
      PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: host,
        port: port,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );

  group('connection to transport mapping', () {
    test('USB on macOS resolves to the CUPS transport, available', () {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.macos);

      final PrinterResolution resolution = factory.create(
        usb(deviceName: 'TVS_RP3200'),
      );

      expect(resolution.support, PrinterTransportSupport.available);
      final TransportThermalPrinter printer =
          resolution.printer as TransportThermalPrinter;
      expect(printer.transport, isA<CupsRawPrintTransport>());
    });

    test('USB on Windows resolves to the spooler transport, available', () {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.windows);

      final PrinterResolution resolution = factory.create(
        usb(deviceName: 'TVS RP 3200 Lite'),
      );

      expect(resolution.support, PrinterTransportSupport.available);
      final TransportThermalPrinter printer =
          resolution.printer as TransportThermalPrinter;
      final WindowsSpoolerPrintTransport transport =
          printer.transport as WindowsSpoolerPrintTransport;
      // The saved deviceName is the Windows print-queue name, passed through unchanged.
      expect(transport.printerName, 'TVS RP 3200 Lite');
    });

    test('USB on an unsupported platform is honestly not installed', () async {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.other);

      final PrinterResolution resolution = factory.create(
        usb(deviceName: 'whatever'),
      );

      expect(resolution.support, PrinterTransportSupport.notInstalled);
      expect(resolution.printer, isA<UnconfiguredThermalPrinter>());
      expect(
        resolution.printer.connectionState,
        PrinterConnectionState.unavailable,
      );
      // It still lays documents out for the real roll, and still refuses to print.
      expect(resolution.printer.profile.paper, PaperWidth.mm80);
      final Result<void> connected = await resolution.printer.connect();
      expect(connected.isErr, isTrue);
    });

    test('a network printer uses a socket on every platform', () {
      for (final PrinterHostPlatform platform in PrinterHostPlatform.values) {
        final PlatformThermalPrinterFactory factory =
            PlatformThermalPrinterFactory(platform: platform);

        final PrinterResolution resolution = factory.create(lan());

        expect(
          resolution.support,
          PrinterTransportSupport.available,
          reason: 'network is served on $platform',
        );
        final TransportThermalPrinter printer =
            resolution.printer as TransportThermalPrinter;
        expect(printer.transport, isA<SocketRawPrintTransport>());
      }
    });

    test('nothing configured resolves to not configured', () {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.macos);

      final PrinterResolution resolution = factory.create(
        PrinterConnectionSettings.unconfigured,
      );

      expect(resolution.support, PrinterTransportSupport.notConfigured);
      expect(resolution.printer, isA<UnconfiguredThermalPrinter>());
    });

    test('the default network socket targets the configured host and port', () {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.macos);

      final SocketRawPrintTransport transport =
          (factory.create(lan(host: '10.0.0.9', port: 9101)).printer
                  as TransportThermalPrinter)
              .transport
          as SocketRawPrintTransport;

      expect(transport.host, '10.0.0.9');
      expect(transport.port, 9101);
    });

    test('a network printer with no port typed defaults to 9100', () {
      final PlatformThermalPrinterFactory factory =
          PlatformThermalPrinterFactory(platform: PrinterHostPlatform.windows);

      final SocketRawPrintTransport transport =
          (factory.create(lan(port: null)).printer as TransportThermalPrinter)
              .transport
          as SocketRawPrintTransport;

      expect(transport.port, 9100);
    });
  });

  group('the produced printer sends through the chosen transport', () {
    late RecordingRawTransport sink;
    late PlatformThermalPrinterFactory factory;

    setUp(() {
      sink = RecordingRawTransport();
      factory = PlatformThermalPrinterFactory(
        platform: PrinterHostPlatform.macos,
        macUsbTransport: (_) => sink,
      );
    });

    PrintJob job(List<int> bytes) => PrintJob(
      id: 'prj-1',
      kind: PrintJobKind.customerReceipt,
      title: 'Receipt 20260915-0001',
      createdAt: DateTime.utc(2026, 9, 15),
      bytes: Uint8List.fromList(bytes),
    );

    test('the encoded bytes reach the transport unchanged (RAW passthrough)', () async {
      final PrinterResolution resolution = factory.create(usb());
      final RawPrintTransport _ = (resolution.printer
              as TransportThermalPrinter)
          .transport;

      final Result<void> sent = await resolution.printer.send(
        job(<int>[0x1B, 0x40, 0x0A, 0xC0, 0xFF]),
      );

      expect(sent.isOk, isTrue);
      expect(sink.openCount, 1);
      expect(sink.writes, hasLength(1));
      expect(sink.lastWrite, <int>[0x1B, 0x40, 0x0A, 0xC0, 0xFF]);
      expect(sink.jobNames.single, 'Receipt 20260915-0001');
    });

    test('a transport that cannot open yields a failure, never a throw', () async {
      sink.failOnOpen = true;
      final PrinterResolution resolution = factory.create(usb());

      final Result<void> sent = await resolution.printer.send(job(<int>[1, 2]));

      expect(sent.isErr, isTrue);
      expect(sink.writes, isEmpty);
    });

    test('a transport that fails mid-write yields a failure, never a throw', () async {
      sink.failOnWrite = true;
      final PrinterResolution resolution = factory.create(usb());

      final Result<void> sent = await resolution.printer.send(job(<int>[1, 2]));

      expect(sent.isErr, isTrue);
      // Nothing recorded: a failed write leaves no half-printed document behind.
      expect(sink.writes, isEmpty);
    });
  });
}
