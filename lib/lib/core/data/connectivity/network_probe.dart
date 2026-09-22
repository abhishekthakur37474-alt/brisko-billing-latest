import 'dart:io';

/// Answers one question: can the terminal reach the cloud right now.
///
/// Behind an interface so the polling monitor can be tested without a network,
/// and so the strategy (a DNS lookup today, a lightweight HTTP HEAD later) can
/// change without touching the monitor.
abstract interface class NetworkProbe {
  Future<bool> isReachable();
}

/// A probe that resolves the cloud host's DNS name.
///
/// A name lookup is the cheapest signal that the device has a working connection
/// to the internet and that the cloud host exists: it sends no request body,
/// transmits no application data, and completes in milliseconds on a live link.
/// The requirement is only ever a boolean — is there any point trying to sync —
/// so a full request would be more than is needed and would waste battery and
/// data on a link that is down.
///
/// When no cloud host is configured there is nothing to reach, so the probe
/// reports unreachable. That is honest: an unconfigured terminal has no backend to
/// be online with, and the UI reports "cloud not configured" separately.
class HostLookupProbe implements NetworkProbe {
  const HostLookupProbe({this.host, this.timeout = const Duration(seconds: 5)});

  /// Host name of the configured cloud backend, for example
  /// `brisko-billing-default-rtdb.asia-southeast1.firebasedatabase.app`.
  /// `null` when no backend is configured.
  final String? host;

  final Duration timeout;

  @override
  Future<bool> isReachable() async {
    final String? target = host;
    if (target == null || target.isEmpty) {
      return false;
    }
    try {
      final List<InternetAddress> addresses = await InternetAddress.lookup(
        target,
      ).timeout(timeout);
      return addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on Object {
      // A timeout or any other lookup fault is simply "not reachable right now".
      // Billing does not depend on the answer, so nothing here is allowed to throw.
      return false;
    }
  }
}
