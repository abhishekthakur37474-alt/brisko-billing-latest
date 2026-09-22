/// The kind of mutation waiting to be replayed against the cloud.
enum OutboxOperation { upsert, delete }

/// A single pending write, durably queued on the device.
///
/// The outbox is what makes offline billing safe. Every write goes to local
/// storage and appends an entry here in the same logical step. When connectivity
/// returns, entries are replayed in queue order, so the cloud ends up with the
/// same sequence of changes the cashier actually performed.
///
/// The entry carries a serialised [payload] snapshot rather than a reference to
/// the live record, which keeps replay deterministic even if the record is edited
/// again before the queue drains.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.collection,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.queuedAt,
    this.attemptCount = 0,
    this.lastError,
  });

  /// Identity of the queue entry itself.
  final String id;

  /// Logical collection the entity belongs to, for example `bills` or
  /// `menu_items`. Maps to an RTDB node later.
  final String collection;

  /// Identity of the entity being written.
  final String entityId;

  final OutboxOperation operation;

  /// Serialised entity snapshot. Empty for [OutboxOperation.delete].
  final Map<String, dynamic> payload;

  final DateTime queuedAt;

  /// Number of failed replay attempts, used for backoff and for surfacing
  /// records that are stuck.
  final int attemptCount;

  /// Message from the most recent failed attempt, for diagnostics.
  final String? lastError;

  OutboxEntry copyWith({int? attemptCount, String? lastError}) {
    return OutboxEntry(
      id: id,
      collection: collection,
      entityId: entityId,
      operation: operation,
      payload: payload,
      queuedAt: queuedAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastError: lastError ?? this.lastError,
    );
  }
}
