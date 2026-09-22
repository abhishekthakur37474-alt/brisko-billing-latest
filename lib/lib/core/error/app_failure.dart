/// A recoverable, user-reportable problem returned by a repository or service.
///
/// Failures are values, not exceptions. Data sources may throw, but repositories
/// convert those throws into an [AppFailure] carried inside a `Result`, so the
/// presentation layer never has to wrap calls in try/catch.
sealed class AppFailure {
  const AppFailure(this.message, {this.cause});

  /// Human-readable message safe to surface in the UI.
  final String message;

  /// Underlying error, kept for logging. Never shown to the cashier.
  final Object? cause;

  @override
  String toString() => '$runtimeType($message)';
}

/// Reading from or writing to on-device storage failed.
final class LocalStorageFailure extends AppFailure {
  const LocalStorageFailure(super.message, {super.cause});
}

/// The device has no usable internet connection.
///
/// This is expected during normal operation. Billing must continue on local
/// storage when this failure occurs.
final class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.cause});
}

/// The cloud backend was reachable but rejected or could not serve the request.
final class RemoteFailure extends AppFailure {
  const RemoteFailure(super.message, {super.cause});
}

/// Input did not satisfy a business rule, for example a discount larger than the
/// order subtotal.
final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.cause});
}

/// A printer could not be reached, or refused a document.
///
/// Its own failure type because it is the one failure that must never be treated as a
/// failed operation upstream. A settled bill whose receipt did not print is a
/// completely successful sale with a paper problem, and the cashier has to be told
/// exactly that. Every other failure here means something did not happen; this one
/// means something happened and was not printed.
final class PrinterFailure extends AppFailure {
  const PrinterFailure(super.message, {super.cause});
}

/// An unclassified error. Indicates a bug rather than an operational condition.
final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure(super.message, {super.cause});
}
