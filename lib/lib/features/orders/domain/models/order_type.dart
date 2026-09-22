/// How the order reaches the customer.
///
/// [delivery] and [onlineManual] are separate because they are different business
/// events even though both end up at a door. A `delivery` order is one the outlet
/// took directly, by phone or at the counter. An `onlineManual` order arrived
/// through an aggregator such as Swiggy or Zomato and was typed into this POS by
/// hand, because there is no API integration. Keeping them apart is what lets a
/// report show direct versus aggregator revenue, and the two carry different
/// commission and settlement realities.
enum OrderType {
  dineIn,
  takeaway,
  delivery,
  onlineManual;

  String get label => switch (this) {
    OrderType.dineIn => 'Dine-in',
    OrderType.takeaway => 'Takeaway',
    OrderType.delivery => 'Delivery',
    OrderType.onlineManual => 'Online (manual)',
  };

  /// True when the order leaves the premises, so an address or phone number
  /// matters.
  bool get isOffPremises =>
      this == OrderType.delivery || this == OrderType.onlineManual;
}
