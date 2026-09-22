import 'dart:io';
import 'dart:typed_data';

import 'raw_print_transport.dart';

/// Dials a network ESC/POS printer and streams bytes to it.
///
/// A network printer — wired LAN or Wi-Fi — listens on a TCP port, almost universally
/// 9100 (the RAW / JetDirect port), and prints whatever is written to the socket. That
/// is the whole protocol: there is no framing and no acknowledgement beyond TCP's own,
/// so "the bytes were accepted" means "the socket took them without the connection
/// breaking". This transport reports exactly that and no more.
///
/// It is platform-independent on purpose. A socket behaves the same on macOS and on
/// Windows, so a network printer needs no per-platform adapter; only the USB path does.
///
/// ## Why the socket is opened per connection, not held for the app's life
///
/// Many ESC/POS network printers accept a single connection at a time. Holding the
/// socket open between bills would refuse a second terminal, and a half-open socket left
/// by a sleeping printer would swallow the next receipt silently. So the printer's
/// connection state machine above this class opens before a document and the operator's
/// reconfiguration closes after, which keeps the port free between uses.
class SocketRawPrintTransport implements RawPrintTransport {
  SocketRawPrintTransport({
    required this.host,
    this.port = _defaultRawPort,
    this.connectTimeout = const Duration(seconds: 5),
    this.writeTimeout = const Duration(seconds: 20),
    RawSocketConnector? connector,
  }) : _connect = connector ?? _dial;

  /// The RAW / JetDirect port every ESC/POS network printer in this class listens on.
  static const int _defaultRawPort = 9100;

  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration writeTimeout;
  final RawSocketConnector _connect;

  // Held across writes and closed in [close]. The close_sinks lint cannot see a sink
  // released through a different method than the one that opened it, so it is silenced
  // here rather than by leaving the socket unclosed.
  // ignore: close_sinks
  Socket? _socket;

  @override
  String get description => '$host:$port';

  @override
  Future<void> open() async {
    if (_socket != null) {
      return;
    }
    // A refused connection, a wrong address or an unreachable printer surfaces here as a
    // SocketException, which the printer base class turns into a "could not reach the
    // printer" failure. The timeout stops a dead address from hanging a bill.
    _socket = await _connect(host, port, timeout: connectTimeout);
  }

  @override
  Future<void> write(Uint8List bytes, {required String jobName}) async {
    // ignore: close_sinks
    final Socket socket = _socket ?? (throw const SocketNotOpenException());

    socket.add(bytes);
    // flush completes when the bytes have been passed to the OS socket buffer, and
    // throws if the connection has broken — which is the strongest "accepted" a one-way
    // RAW socket can offer. A printer that is switched off mid-write breaks the socket,
    // and that throw becomes the failure the cashier sees.
    await socket.flush().timeout(writeTimeout);
  }

  @override
  Future<void> close() async {
    final Socket? socket = _socket;
    _socket = null;
    if (socket == null) {
      return;
    }
    // Best effort flush before tearing the socket down, so a document sent immediately
    // before a reconfiguration is not truncated.
    try {
      await socket.flush().timeout(writeTimeout);
    } finally {
      socket.destroy();
    }
  }

  static Future<Socket> _dial(
    String host,
    int port, {
    Duration? timeout,
  }) => Socket.connect(host, port, timeout: timeout);
}

/// Opens a TCP connection to a printer. Injected so a test can supply a socket backed by
/// a loopback server rather than a real device.
typedef RawSocketConnector = Future<Socket> Function(
  String host,
  int port, {
  Duration? timeout,
});

/// Thrown when a write is attempted before the socket was opened. A programming fault in
/// this layer rather than an operational one, but modelled as an exception so the printer
/// base class reports it like any other transport failure instead of crashing a bill.
class SocketNotOpenException implements Exception {
  const SocketNotOpenException();

  @override
  String toString() => 'SocketNotOpenException(the printer socket is not open)';
}
