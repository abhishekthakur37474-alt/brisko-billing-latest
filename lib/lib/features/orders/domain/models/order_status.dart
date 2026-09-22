/// Where an order stands in the outlet's workflow.
///
/// Kept to the six states the counter actually distinguishes. The kitchen has no
/// screen of its own, so [preparing] and [ready] are updated by whoever is at the
/// till, and neither blocks billing.
enum OrderStatus {
  /// Being built at the counter. Not yet a commitment, and not counted in sales.
  draft,

  /// Committed. The kitchen slip can be printed from here.
  confirmed,

  preparing,

  ready,

  /// Served or handed over, and settled.
  completed,

  cancelled;

  String get label => switch (this) {
    OrderStatus.draft => 'Draft',
    OrderStatus.confirmed => 'Confirmed',
    OrderStatus.preparing => 'Preparing',
    OrderStatus.ready => 'Ready',
    OrderStatus.completed => 'Completed',
    OrderStatus.cancelled => 'Cancelled',
  };

  /// True once the order is a real commitment and should appear in sales figures.
  ///
  /// A draft is excluded because it may never be placed, and a cancellation is
  /// excluded because it was reversed. Reports rely on this rather than each
  /// re-deciding which states count.
  bool get countsTowardsSales =>
      this != OrderStatus.draft && this != OrderStatus.cancelled;

  /// True when no further work is expected.
  bool get isClosed =>
      this == OrderStatus.completed || this == OrderStatus.cancelled;
}
