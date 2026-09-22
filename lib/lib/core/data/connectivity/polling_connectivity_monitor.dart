import 'dart:async';

import 'connectivity_monitor.dart';
import 'network_probe.dart';

/// A [ConnectivityMonitor] that checks reachability on a gentle timer.
///
/// ## Why polling, and why gently
///
/// The platform channels that report link state are not available in the plain
/// Dart layer this application is built on, and pulling in a plugin for it would
/// add a native dependency to every platform for a single boolean. A periodic
/// probe answers the only question the sync engine asks — is there any point
/// trying to reach the cloud — without any of that.
///
/// The interval is deliberately long. The requirement is explicit that the network
/// must not be polled continuously: a terminal that is offline for an hour should
/// not make hundreds of lookups in that hour. So the default is one probe every
/// thirty seconds, and a caller that has a better signal (a failed request, a
/// manual "sync now") can call [refresh] to check immediately rather than waiting
/// for the next tick.
///
/// The monitor never gates billing. Its only job is to tell the coordinator when
/// the link comes back so a drain can start; if it is wrong for one interval, the
/// worst case is a sync that starts thirty seconds late or a push that fails and
/// stays queued, both of which are already handled.
class PollingConnectivityMonitor implements ConnectivityMonitor {
  PollingConnectivityMonitor({
    required this._probe,
    this.interval = const Duration(seconds: 30),
  });

  final NetworkProbe _probe;

  /// How often reachability is re-checked. Long by default; the network must not
  /// be polled continuously.
  final Duration interval;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool _isOnline = false;
  bool _isStarted = false;
  bool _isDisposed = false;
  Timer? _timer;
  bool _probeInFlight = false;

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get onConnectivityChanged => _changes.stream;

  /// Begins probing. Runs one probe immediately so the first status is real
  /// rather than the pessimistic default, then repeats on the interval.
  void start() {
    if (_isStarted || _isDisposed) {
      return;
    }
    _isStarted = true;
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Probes once, now. Used on start-up and whenever a caller has reason to think
  /// the answer has changed, so the link returning is noticed without waiting for
  /// the next tick.
  Future<void> refresh() async {
    if (_isDisposed || _probeInFlight) {
      return;
    }
    _probeInFlight = true;
    try {
      final bool reachable = await _probe.isReachable();
      _update(reachable);
    } finally {
      _probeInFlight = false;
    }
  }

  void _update(bool reachable) {
    if (_isDisposed || reachable == _isOnline) {
      return;
    }
    _isOnline = reachable;
    if (!_changes.isClosed) {
      _changes.add(reachable);
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _timer?.cancel();
    _timer = null;
    await _changes.close();
  }
}
