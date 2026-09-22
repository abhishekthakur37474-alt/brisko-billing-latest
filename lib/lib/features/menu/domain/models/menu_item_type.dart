/// Food classification of a menu item, in the sense Indian menus and FSSAI
/// labelling use.
///
/// Drives the green/brown dot on the receipt and lets a report separate veg from
/// non-veg sales. It is not a structural type: whether an item has size variants is
/// determined by whether variant rows exist for it, not by this value.
///
/// The outlet's menu appears to be entirely vegetarian. The other values exist so
/// that adding a non-veg item later needs no migration.
enum MenuItemType {
  veg,
  egg,
  nonVeg;

  /// Symbol conventionally printed next to the item name.
  String get marker => switch (this) {
    MenuItemType.veg => 'VEG',
    MenuItemType.egg => 'EGG',
    MenuItemType.nonVeg => 'NON-VEG',
  };
}
