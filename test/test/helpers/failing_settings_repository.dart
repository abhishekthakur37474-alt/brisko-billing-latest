import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/settings/domain/repositories/settings_repository.dart';

/// A settings repository that can be told to fail, wrapping a real one.
///
/// ## Why it wraps rather than replaces
///
/// The interesting cases are not "reads fail" and "writes fail" on their own. They are
/// "the save failed and what was on disk beforehand is still there", and "the read failed
/// and the screen said so instead of throwing". Both need a real table underneath, so this
/// delegates every call it is not currently refusing to the genuine SQLite repository.
///
/// [writeAllCount] is what a duplicate-submission test asserts on: pressing Save twice
/// must reach storage once.
class FailingSettingsRepository implements SettingsRepository {
  FailingSettingsRepository({
    required this.delegate,
    this.failReads = false,
    this.failWrites = false,
  });

  final SettingsRepository delegate;

  /// When true, every read is refused with a storage failure.
  bool failReads;

  /// When true, every write is refused, and nothing reaches the table.
  bool failWrites;

  /// Writes attempted, including the ones that were refused.
  int writeAllCount = 0;

  /// What the operator would be told.
  static const String readMessage = 'The settings could not be read.';
  static const String writeMessage = 'The settings could not be saved.';

  @override
  Future<Result<Map<String, String?>>> readAll() {
    if (failReads) {
      return _refuseRead<Map<String, String?>>();
    }
    return delegate.readAll();
  }

  @override
  Future<Result<void>> writeAll(Map<String, String?> values) async {
    writeAllCount++;
    if (failWrites) {
      return _refuseWrite();
    }
    return delegate.writeAll(values);
  }

  @override
  Future<Result<bool>> readBool(String key, {bool defaultValue = false}) {
    if (failReads) {
      return _refuseRead<bool>();
    }
    return delegate.readBool(key, defaultValue: defaultValue);
  }

  @override
  Future<Result<int?>> readInt(String key) {
    if (failReads) {
      return _refuseRead<int?>();
    }
    return delegate.readInt(key);
  }

  @override
  Future<Result<String?>> readString(String key) {
    if (failReads) {
      return _refuseRead<String?>();
    }
    return delegate.readString(key);
  }

  @override
  Future<Result<void>> remove(String key) {
    if (failWrites) {
      return Future<Result<void>>.value(_refuseWrite());
    }
    return delegate.remove(key);
  }

  @override
  Future<Result<void>> writeBool(String key, bool value) {
    if (failWrites) {
      return Future<Result<void>>.value(_refuseWrite());
    }
    return delegate.writeBool(key, value);
  }

  @override
  Future<Result<void>> writeInt(String key, int value) {
    if (failWrites) {
      return Future<Result<void>>.value(_refuseWrite());
    }
    return delegate.writeInt(key, value);
  }

  @override
  Future<Result<void>> writeString(String key, String value) {
    if (failWrites) {
      return Future<Result<void>>.value(_refuseWrite());
    }
    return delegate.writeString(key, value);
  }

  static Future<Result<T>> _refuseRead<T>() async =>
      const Err<Never>(LocalStorageFailure(readMessage));

  static Result<void> _refuseWrite() =>
      const Err<void>(LocalStorageFailure(writeMessage));
}
