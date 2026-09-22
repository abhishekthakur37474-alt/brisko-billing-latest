import 'dart:async';

import 'app_failure.dart';

/// A single place failures are announced so the shell can show them on screen.
///
/// Failures normally travel back to their caller inside a `Result` and are rendered
/// by the screen that asked for the work. Some faults happen where no screen is
/// listening -- a write on a section the operator has since left, a background
/// sync, a start-up step -- and those would otherwise be invisible. Data-layer
/// boundaries report such a failure here and the application shell renders it, so
/// an error is seen at the terminal rather than written to a file nobody reads.
class AppErrorReporter {
  AppErrorReporter._();

  /// The one reporter the running application uses.
  static final AppErrorReporter instance = AppErrorReporter._();

  final StreamController<AppFailure> _controller =
      StreamController<AppFailure>.broadcast();

  /// Failures announced by the application, in the order they were reported.
  Stream<AppFailure> get failures => _controller.stream;

  /// Announces [failure] so it can be shown to the operator.
  ///
  /// Safe to call before any widget is listening: the broadcast stream simply has
  /// no subscriber and nothing is retained.
  void report(AppFailure failure) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(failure);
  }
}
