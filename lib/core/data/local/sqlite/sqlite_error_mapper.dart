import 'package:sqflite/sqflite.dart';

import '../../../error/app_failure.dart';
import '../../../utils/result.dart';

/// Converts database exceptions into the application's failure model.
///
/// This is the boundary where throwing stops. Above it, every data-layer call
/// returns a `Result`, so no feature or widget ever sees a `DatabaseException` or
/// has to know that SQLite is involved. Raw exception text is kept in
/// `AppFailure.cause` for logging and is never shown to the cashier.
class SqliteErrorMapper {
  const SqliteErrorMapper._();

  /// Runs [action], returning its value on success and a mapped failure if it
  /// throws.
  ///
  /// [context] describes the attempted operation in operator-facing language, for
  /// example `'save the order'`.
  static Future<Result<T>> guard<T>(
    Future<T> Function() action, {
    required String context,
  }) async {
    try {
      return Ok<T>(await action());
    } on DatabaseException catch (error, stackTrace) {
      return Err<T>(_mapDatabaseException(error, context, stackTrace));
    } on ArgumentError catch (error) {
      // Thrown by the model layer for a value that cannot be persisted, such as a
      // negative quantity. That is a rule violation, not a storage fault.
      return Err<T>(
        ValidationFailure(
          error.message?.toString() ?? 'Invalid value',
          cause: error,
        ),
      );
    } on FormatException catch (error) {
      return Err<T>(
        ValidationFailure('Could not read a stored value.', cause: error),
      );
    } catch (error) {
      return Err<T>(UnexpectedFailure('Could not $context.', cause: error));
    }
  }

  static AppFailure _mapDatabaseException(
    DatabaseException error,
    String context,
    StackTrace stackTrace,
  ) {
    if (error.isUniqueConstraintError()) {
      return ValidationFailure('That record already exists.', cause: error);
    }
    if (error.isNotNullConstraintError()) {
      return ValidationFailure('A required value was missing.', cause: error);
    }
    // A foreign key violation means something referenced a row that is absent,
    // for example an order item pointing at a deleted menu item. That is a bug in
    // the caller rather than a storage fault, but it is reported as a validation
    // problem because it is recoverable by correcting the input.
    if (error.isDatabaseClosedError()) {
      return LocalStorageFailure(
        'The local database is closed. Restart the application.',
        cause: error,
      );
    }
    if (error.isReadOnlyError()) {
      return LocalStorageFailure(
        'The local database cannot be saved. Restart the application. If this '
        'keeps happening, move Brisko Billing out of a protected folder '
        '(for example Program Files) and open it again.',
        cause: error,
      );
    }
    return LocalStorageFailure('Could not $context.', cause: error);
  }
}
