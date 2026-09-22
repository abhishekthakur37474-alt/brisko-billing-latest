/// Reports whether the terminal currently has usable internet access.
///
/// Deliberately narrow: the rest of the application only ever needs a boolean.
/// Keeping it behind this interface means the detection strategy can change
/// without touching the synchronisation engine or any feature module.
abstract interface class ConnectivityMonitor {
  /// Last known connectivity state.
  bool get isOnline;

  /// Emits on every transition. The synchronisation engine listens here to start
  /// draining the outbox as soon as the connection returns.
  Stream<bool> get onConnectivityChanged;
}
