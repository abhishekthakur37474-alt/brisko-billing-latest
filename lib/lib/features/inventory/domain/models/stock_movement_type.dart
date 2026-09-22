/// Why stock moved.
///
/// The direction of a movement is derived from the type rather than stored, so a
/// wastage entry cannot accidentally be recorded as an increase.
///
/// ## Why `stockIn` and not `purchase`
///
/// The value was called `purchase` before recipes existed. It is `stockIn` now
/// because that is the operation the outlet performs: stock arrives and is put on the
/// shelf. Procurement — purchase orders, vendors, supplier accounts — is explicitly
/// not part of this product, and a type called `purchase` implied a workflow that
/// does not exist. Migration v6 retokenises any stored `purchase` row.
enum StockMovementType {
  /// Stock received and put on the shelf. Increases the balance.
  stockIn,

  /// Consumed by selling something. Decreases the balance.
  ///
  /// The only type the application writes on its own, always with the settled order
  /// id as its reference.
  sale,

  /// Correction after a physical count. Signed by the recorded quantity, since a
  /// count can go either way.
  adjustment,

  /// Spoiled, dropped or otherwise lost. Decreases the balance.
  wastage,

  /// Removed for a reason that is not a sale and not a loss, for example stock sent
  /// out for an event. Decreases the balance.
  stockOut;

  String get label => switch (this) {
    StockMovementType.stockIn => 'Stock in',
    StockMovementType.sale => 'Sale',
    StockMovementType.adjustment => 'Adjustment',
    StockMovementType.wastage => 'Wastage',
    StockMovementType.stockOut => 'Stock out',
  };

  /// What the operator is asked to enter, on the form for this movement.
  String get quantityPrompt => switch (this) {
    StockMovementType.stockIn => 'Quantity received',
    StockMovementType.sale => 'Quantity sold',
    StockMovementType.adjustment => 'Correction, positive or negative',
    StockMovementType.wastage => 'Quantity wasted',
    StockMovementType.stockOut => 'Quantity removed',
  };

  /// How this movement affects the running balance: `1` to add, `-1` to subtract, or
  /// `0` when the recorded quantity already carries its own sign.
  int get direction => switch (this) {
    StockMovementType.stockIn => 1,
    StockMovementType.sale => -1,
    StockMovementType.wastage => -1,
    StockMovementType.stockOut => -1,
    StockMovementType.adjustment => 0,
  };

  /// True when the quantity entered must be positive, the direction being implied by
  /// the type. False only for [adjustment], which is signed by the operator.
  bool get requiresPositiveQuantity => direction != 0;

  /// True when the operator raises this movement themselves.
  ///
  /// [sale] is the exception: it is written by settlement from a configured recipe,
  /// and offering it as a manual action would let someone record a sale that no bill
  /// accounts for.
  bool get isManual => this != StockMovementType.sale;

  /// The movements an operator can raise from the inventory screen, in the order the
  /// screen offers them.
  static const List<StockMovementType> manual = <StockMovementType>[
    StockMovementType.stockIn,
    StockMovementType.adjustment,
    StockMovementType.wastage,
    StockMovementType.stockOut,
  ];
}
