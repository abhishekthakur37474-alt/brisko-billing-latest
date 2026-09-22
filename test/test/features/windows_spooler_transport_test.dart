import 'dart:typed_data';

import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/windows_spooler_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Windows spooler transport, with the Win32 FFI behind a fake so its logic — reject
/// a missing queue, send the RAW bytes verbatim, turn a spooler fault into a failure —
/// is verified on any machine. The real `Win32RawPrinterApi` can only be exercised on
/// Windows; that remains a client-machine validation and is called out in the report.
void main() {
  PrintJob job(List<int> bytes, {String title = 'Receipt 1'}) => PrintJob(
    id: 'prj-1',
    kind: PrintJobKind.customerReceipt,
    title: title,
    createdAt: DateTime.utc(2026, 9, 15),
    bytes: Uint8List.fromList(bytes),
  );

  test('open refuses a printer name Windows does not have', () async {
    final FakeWindowsPrinterApi api = FakeWindowsPrinterApi(exists: false);
    final WindowsSpoolerPrintTransport transport =
        WindowsSpoolerPrintTransport(printerName: 'Nope', api: api);

    await expectLater(
      transport.open(),
      throwsA(
        isA<WindowsSpoolerException>().having(
          (WindowsSpoolerException e) => e.message,
          'message',
          contains('Nope'),
        ),
      ),
    );
  });

  test('open accepts a printer name Windows has', () async {
    final FakeWindowsPrinterApi api = FakeWindowsPrinterApi(exists: true);
    final WindowsSpoolerPrintTransport transport =
        WindowsSpoolerPrintTransport(printerName: 'TVS RP 3200 Lite', api: api);

    await transport.open();

    expect(api.existsQueries, <String>['TVS RP 3200 Lite']);
  });

  test('write sends the RAW bytes verbatim to the named queue', () async {
    final FakeWindowsPrinterApi api = FakeWindowsPrinterApi(exists: true);
    final WindowsSpoolerPrintTransport transport =
        WindowsSpoolerPrintTransport(printerName: 'TVS RP 3200 Lite', api: api);
    await transport.open();

    final Uint8List bytes = Uint8List.fromList(<int>[0x1B, 0x40, 0x1D, 0x56, 0x00]);
    await transport.write(bytes, jobName: 'Receipt 7');

    expect(api.sends, hasLength(1));
    final SendRaw sent = api.sends.single;
    expect(sent.printerName, 'TVS RP 3200 Lite');
    expect(sent.jobName, 'Receipt 7');
    expect(sent.bytes, bytes);
  });

  test('a spooler fault becomes a failure, never a throw, through the seam', () async {
    final FakeWindowsPrinterApi api = FakeWindowsPrinterApi(
      exists: true,
      sendFault: 'Writing failed (error 63).',
    );
    final TransportThermalPrinter printer = TransportThermalPrinter(
      transport: WindowsSpoolerPrintTransport(
        printerName: 'TVS RP 3200 Lite',
        api: api,
      ),
      endpoint: const PrinterEndpoint.usb(deviceName: 'TVS RP 3200 Lite'),
    );

    final Result<void> sent = await printer.send(job(<int>[1, 2, 3]));

    expect(sent.isErr, isTrue);
    await printer.dispose();
  });

  test('a healthy spooler send reports Ok through the seam', () async {
    final FakeWindowsPrinterApi api = FakeWindowsPrinterApi(exists: true);
    final TransportThermalPrinter printer = TransportThermalPrinter(
      transport: WindowsSpoolerPrintTransport(
        printerName: 'TVS RP 3200 Lite',
        api: api,
      ),
      endpoint: const PrinterEndpoint.usb(deviceName: 'TVS RP 3200 Lite'),
    );

    final Result<void> sent = await printer.send(job(<int>[0x1B, 0x40]));

    expect(sent.isOk, isTrue);
    expect(api.sends.single.bytes, <int>[0x1B, 0x40]);
    await printer.dispose();
  });
}

class SendRaw {
  const SendRaw(this.printerName, this.jobName, this.bytes);

  final String printerName;
  final String jobName;
  final Uint8List bytes;
}

/// A stand-in for the Win32 spooler. Records what it was asked to do and can be told the
/// queue is missing or that the write fails, so the transport's behaviour is verified
/// without Windows.
class FakeWindowsPrinterApi implements WindowsRawPrinterApi {
  FakeWindowsPrinterApi({required this.exists, this.sendFault});

  final bool exists;
  final String? sendFault;

  final List<String> existsQueries = <String>[];
  final List<SendRaw> sends = <SendRaw>[];

  @override
  bool printerExists(String printerName) {
    existsQueries.add(printerName);
    return exists;
  }

  @override
  void sendRaw({
    required String printerName,
    required String jobName,
    required Uint8List bytes,
  }) {
    if (sendFault != null) {
      throw WindowsSpoolerException(sendFault!);
    }
    sends.add(SendRaw(printerName, jobName, Uint8List.fromList(bytes)));
  }
}
