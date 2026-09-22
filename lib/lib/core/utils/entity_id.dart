import 'dart:math';

/// Generates identifiers on the device rather than on the server.
///
/// This matters for offline-first billing: a bill created while the internet is
/// down already has its final, permanent id. When the record is later pushed to
/// the cloud it keeps the same id, so nothing has to be renumbered or remapped
/// after synchronising.
///
/// The format is a millisecond timestamp followed by random entropy, both base36
/// encoded. Ids therefore sort chronologically as plain strings, which keeps
/// local queries and cloud document ordering consistent.
class EntityId {
  const EntityId._();

  static final Random _random = Random.secure();

  static const int _entropyChars = 8;

  /// Returns a new unique identifier, optionally namespaced by [prefix]
  /// (for example `'bill'` or `'order'`).
  static String generate({String? prefix}) {
    final String timestamp = DateTime.now()
        .toUtc()
        .millisecondsSinceEpoch
        .toRadixString(36);

    final StringBuffer entropy = StringBuffer();
    for (int i = 0; i < _entropyChars; i++) {
      entropy.write(_random.nextInt(36).toRadixString(36));
    }

    final String id = '$timestamp$entropy';
    return prefix == null ? id : '$prefix-$id';
  }

  /// Returns a stable, reproducible identifier for seeded reference data.
  ///
  /// Seed rows cannot use [generate], because a random id would be different on
  /// every run and re-seeding would insert duplicates instead of matching the
  /// existing row. Deriving the id from a fixed [prefix] and [slug] makes the
  /// primary key itself the idempotency key, so a seed can safely run again.
  ///
  /// Only ever use this for data defined in a migration. Anything the operator
  /// creates must use [generate].
  static String seeded(String prefix, String slug) {
    final String normalised = slug
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '$prefix-$normalised';
  }
}
