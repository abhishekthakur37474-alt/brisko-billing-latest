/// How widely a menu option applies.
///
/// Derived from which scope columns a `MenuItemOption` row has set, never stored
/// directly, so the scope cannot disagree with the relationships it describes.
///
/// [specificity] exists to resolve an option that is reachable through more than
/// one scope. If the outlet sets a general Extra Cheese price for the whole pizza
/// category and then a different one for a Large Farmhouse specifically, the
/// narrower row must win. Higher wins.
enum MenuOptionScope {
  /// Priced for one exact size of one product, for example Extra Cheese on a
  /// Medium Farmfresh. This is what size-dependent pricing uses.
  variant(specificity: 3),

  /// Applies to one product at any size.
  item(specificity: 2),

  /// Applies to every product in one category.
  category(specificity: 1),

  /// Applies to every product.
  global(specificity: 0);

  const MenuOptionScope({required this.specificity});

  /// Precedence when the same option name is reachable through several scopes.
  final int specificity;

  String get label => switch (this) {
    MenuOptionScope.variant => 'This size only',
    MenuOptionScope.item => 'This item',
    MenuOptionScope.category => 'This category',
    MenuOptionScope.global => 'All items',
  };
}
