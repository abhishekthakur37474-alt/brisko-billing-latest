/// What kind of customisation a menu option represents.
///
/// The grouping matters at the counter, because the three kinds behave
/// differently: a crust is a choice between alternatives, an add-on can be stacked,
/// and a condiment is a small extra. Keeping the distinction in data means the
/// billing screen can lay them out correctly without hard-coding option names in a
/// widget.
enum MenuOptionType {
  /// A base choice such as Thin Crust or Cheese Burst. One per item.
  crust,

  /// A paid addition such as Extra Cheese or Extra Toppings. Stackable.
  addOn,

  /// A small extra such as Ketchup.
  condiment;

  String get label => switch (this) {
    MenuOptionType.crust => 'Crust',
    MenuOptionType.addOn => 'Add-on',
    MenuOptionType.condiment => 'Condiment',
  };
}
