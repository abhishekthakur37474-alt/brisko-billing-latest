import 'dart:io';
import 'dart:typed_data';

import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/socket_raw_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// The network transport, against a real loopback server standing in for a JetDirect /
/// RAW port-9100 printer. This is as close to a physical network printer as a test can
/// get without one: a real TCP connection, real bytes on the wire, and a real broken
/// connection for the failure path.
void main() {
  PrintJob job(List<int> bytes, {String title = 'Receipt 1'}) => PrintJob(
    id: 'prj-1',
    kind: PrintJobKind.customerReceipt,
    title: title,
    createdAt: DateTime.utc(2026, 9, 15),
    bytes: Uint8List.fromList(bytes),
  );

  test('the encoded bytes arrive on the wire verbatim (RAW passthrough)', () async {
    final _FakeNetworkPrinter server = await _FakeNetworkPrinter.start();
    addTearDown(server.stop);

    final SocketRawPrintTransport transport = SocketRawPrintTransport(
      host: server.host,
      port: server.port,
    );

    await transport.open();
    final Uint8List bytes = Uint8List.fromList(<int>[0x1B, 0x40, 0x0A, 0xFF, 0x1D, 0x56, 0x00]);
    await transport.write(bytes, jobName: 'Receipt 5');
    await transport.close();

    final List<int> received = await server.received(bytes.length);
    expect(received, bytes);
  });

  test('connecting to a port nothing listens on is a failure, not a throw', () async {
    // Bind then immediately release a port, so a connection to it is refused.
    final ServerSocket probe = await ServerSocket.bind('127.0.0.1', 0);
    final int deadPort = probe.port;
    await probe.close();

    final TransportThermalPrinter printer = TransportThermalPrinter(
      transport: SocketRawPrintTransport(
        host: '127.0.0.1',
        port: deadPort,
        connectTimeout: const Duration(seconds: 2),
      ),
      endpoint: PrinterEndpoint.lan(host: '127.0.0.1', port: deadPort),
    );

    final Result<void> sent = await printer.send(job(<int>[1, 2, 3]));

    expect(sent.isErr, isTrue);
    await printer.dispose();
  });

  test('writing before opening is reported, not crashed', () async {
    final SocketRawPrintTransport transport = SocketRawPrintTransport(
      host: '127.0.0.1',
      port: 9100,
    );

    await expectLater(
      transport.write(Uint8List.fromList(<int>[1]), jobName: 'R'),
      throwsA(isA<SocketNotOpenException>()),
    );
  });

  test('a full send through the seam succeeds and reaches the printer', () async {
    final _FakeNetworkPrinter server = await _FakeNetworkPrinter.start();
    addTearDown(server.stop);

    final TransportThermalPrinter printer = TransportThermalPrinter(
      transport: SocketRawPrintTransport(host: server.host, port: server.port),
      endpoint: PrinterEndpoint.lan(host: server.host, port: server.port),
    );

    final Result<void> sent = await printer.send(job(<int>[0x1B, 0x40, 0x41]));

    expect(sent.isOk, isTrue);
    final List<int> received = await server.received(3);
    expect(received, <int>[0x1B, 0x40, 0x41]);
    await printer.dispose();
  });
}

/// A loopback TCP server that accepts one connection and accumulates the bytes written to
/// it, exactly as a RAW / port-9100 network printer would receive them.
class _FakeNetworkPrinter {
  _FakeNetworkPrinter(this._server) {
    _server.listen((Socket socket) {
      socket.listen(_buffer.addAll);
    });
  }

  final ServerSocket _server;
  final List<int> _buffer = <int>[];

  static Future<_FakeNetworkPrinter> start() async {
    final ServerSocket server = await ServerSocket.bind('127.0.0.1', 0);
    return _FakeNetworkPrinter(server);
  }

  String get host => _server.address.address;
  int get port => _server.port;

  /// Completes once at least [length] bytes have been received.
  Future<List<int>> received(int length) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_buffer.length < length && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return List<int>.unmodifiable(_buffer);
  }

  Future<void> stop() => _server.close();
}
