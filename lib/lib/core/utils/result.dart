import '../error/app_failure.dart';

/// The outcome of an operation that can fail: either [Ok] or [Err].
///
/// Repositories and services return `Result` instead of throwing, which forces
/// callers to handle the failure path and keeps error handling out of widgets.
sealed class Result<T> {
  const Result();

  /// Wraps a successful value.
  const factory Result.ok(T value) = Ok<T>;

  /// Wraps a failure.
  const factory Result.err(AppFailure failure) = Err<T>;

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  /// The value on success, or `null` on failure.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final T value) => value,
    Err<T>() => null,
  };

  /// The failure on error, or `null` on success.
  AppFailure? get failureOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final AppFailure failure) => failure,
  };

  /// Collapses both branches into a single value.
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(AppFailure failure) onErr,
  }) => switch (this) {
    Ok<T>(:final T value) => onOk(value),
    Err<T>(:final AppFailure failure) => onErr(failure),
  };

  /// Transforms a successful value, passing failures through untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final T value) => Ok<R>(transform(value)),
    Err<T>(:final AppFailure failure) => Err<R>(failure),
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);

  final AppFailure failure;
}
