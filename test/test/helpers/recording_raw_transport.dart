import 'dart:typed_data';

import 'package:brisko_billing/features/printing/data/printers/transport/raw_print_transport.dart';

/// A [RawPrintTransport] that records what it was asked to do, for asserting the byte
/// stream and the lifecycle without a real device.
///
/// It is the transport-level counterpart of `FakeEscPosPrinter`: where that stands in for
/// a whole printer, this stands in for the thin platform sink beneath one, so a test can
/// prove that [TransportThermalPrinter] hands the encoded document over unchanged and that
/// a thrown transport fault becomes a `PrinterFailure` rather than a crash.
///
/// It records that bytes were handed over. It does not claim a printer was reached.
class RecordingRawTransport implements RawPrintTransport {
  RecordingRawTransport({this.name = 'recording'});

  final String name;

  final List<Uint8List> writes = <Uint8List>[];
  final List<String> jobNames = <String>[];
  int openCount = 0;
  int closeCount = 0;

  /// When true, [open] throws, as an unplugged cable or a missing queue would.
  bool failOnOpen = false;

  /// When true, [write] throws part way through, as a jam or a short write would.
  bool failOnWrite = false;

  String faultMessage = 'transport fault';

  Uint8List get lastWrite => writes.last;

  @override
  String get description => name;

  @override
  Future<void> open() async {
    openCount++;
    if (failOnOpen) {
      throw RecordingTransportException(faultMessage);
    }
  }

  @override
  Future<void> write(Uint8List bytes, {required String jobName}) async {
    if (failOnWrite) {
      // Thrown before recording, so a failed write leaves nothing behind.
      throw RecordingTransportException(faultMessage);
    }
    // Copied so a later mutation of the source cannot rewrite history.
    writes.add(Uint8List.fromList(bytes));
    jobNames.add(jobName);
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

class RecordingTransportException implements Exception {
  const RecordingTransportException(this.message);

  final String message;

  @override
  String toString() => 'RecordingTransportException($message)';
}
