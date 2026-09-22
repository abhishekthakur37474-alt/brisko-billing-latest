import 'dart:async';

import 'package:brisko_billing/core/data/connectivity/connectivity_monitor.dart';

/// A [ConnectivityMonitor] a test can flip on and off, so the coordinator's
/// connectivity-triggered behaviour can be driven deterministically.
class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.online = true});

  bool online;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  @override
  bool get isOnline => online;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  /// Emits a transition. A no-op if the value is unchanged, like the real one.
  void setOnline(bool value) {
    if (value == online) {
      return;
    }
    online = value;
    _controller.add(value);
  }

  Future<void> dispose() => _controller.close();
}
