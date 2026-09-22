import '../../sync/sync_state.dart';

/// Conversions between SQLite's four storage types and the types the domain uses.
///
/// SQLite has no boolean, no enum and no date. Rather than repeat the same casts
/// in fourteen models, the encoding rules live here once:
///
/// * `bool` is `INTEGER` 0 or 1.
/// * `DateTime` is `INTEGER` milliseconds since the Unix epoch, always UTC.
/// * enums are `TEXT` holding the Dart value name, so the stored data stays
///   readable and reordering the declaration cannot corrupt it.
extension SqliteRow on Map<String, Object?> {
  String requireString(String column) => this[column]! as String;

  String? optionalString(String column) => this[column] as String?;

  int requireInt(String column) => this[column]! as int;

  int optionalInt(String column, {int fallback = 0}) =>
      this[column] as int? ?? fallback;

  bool requireBool(String column) => requireInt(column) != 0;

  DateTime requireDateTime(String column) =>
      DateTime.fromMillisecondsSinceEpoch(requireInt(column), isUtc: true);

  DateTime? optionalDateTime(String column) {
    final int? value = this[column] as int?;
    if (value == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  /// Reads an enum stored by name.
  ///
  /// Falls back to [fallback] for an unrecognised value, which can only happen if
  /// a newer build wrote a value this one does not know. Failing the whole read
  /// would make a bill unopenable, so it degrades instead.
  E requireEnum<E extends Enum>(
    String column,
    List<E> values, {
    required E fallback,
  }) {
    final String? stored = this[column] as String?;
    if (stored == null) {
      return fallback;
    }
    for (final E value in values) {
      if (value.name == stored) {
        return value;
      }
    }
    return fallback;
  }

  SyncState requireSyncState(String column) => requireEnum<SyncState>(
    column,
    SyncState.values,
    fallback: SyncState.pending,
  );
}

/// Encoders for writing domain values back into a row.
class SqliteValue {
  const SqliteValue._();

  static int fromBool(bool value) => value ? 1 : 0;

  static int fromDateTime(DateTime value) =>
      value.toUtc().millisecondsSinceEpoch;
}
