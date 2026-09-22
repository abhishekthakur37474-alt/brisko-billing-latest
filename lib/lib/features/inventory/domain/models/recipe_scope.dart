/// What a recipe belongs to: a product, or one size of a product.
///
/// ## Why the scope is a type
///
/// Deduction, the repository and the recipe screen all have to agree on which recipe
/// applies to a sold line. Passing `(menuItemId, variantId)` around as two loose
/// arguments invites a call that swaps them or forgets that a `null` variant is
/// meaningful rather than missing. A value type with equality also makes the scope
/// usable as a map key, which is exactly what the deduction needs when it groups a
/// bill's ingredient rows.
///
/// ## Why a null variant is a real scope
///
/// A burger has one price and no sizes, so its recipe is scoped to the product. A
/// pizza's sizes each use a different amount of dough, so those recipes are scoped to
/// the variant. Both are legitimate, and [variantId] being `null` says "this recipe is
/// for the product however it is sold" rather than "the variant is unknown".
///
/// Resolution order is defined by [RecipeScope]'s two constructors and applied in the
/// deduction: a sold line at a size uses the recipe for that size if one is
/// configured, and the product-level recipe otherwise. That lets an outlet write one
/// recipe covering every size and override a single size later, without restructuring
/// anything.
class RecipeScope {
  /// The recipe for a product sold at one price, or shared by all of its sizes.
  const RecipeScope.product(this.menuItemId) : variantId = null;

  /// The recipe for one size of a product.
  const RecipeScope.variant({
    required this.menuItemId,
    required String this.variantId,
  });

  /// The product this recipe is for. Always present: a recipe with no product could
  /// never be reached from a bill line.
  final String menuItemId;

  /// The size this recipe is for, or `null` for a product-level recipe.
  final String? variantId;

  bool get isVariantScoped => variantId != null;

  /// The scope this one falls back to, or `null` when there is nothing broader.
  ///
  /// A variant-scoped recipe falls back to its product. A product-level recipe is
  /// already the broadest scope there is; it does not fall back to a category,
  /// because ingredients are a property of the dish rather than of the section of the
  /// menu it is printed under.
  RecipeScope? get fallback =>
      isVariantScoped ? RecipeScope.product(menuItemId) : null;

  @override
  bool operator ==(Object other) =>
      other is RecipeScope &&
      other.menuItemId == menuItemId &&
      other.variantId == variantId;

  @override
  int get hashCode => Object.hash(menuItemId, variantId);

  @override
  String toString() => variantId == null
      ? 'RecipeScope.product($menuItemId)'
      : 'RecipeScope.variant($menuItemId, $variantId)';
}
