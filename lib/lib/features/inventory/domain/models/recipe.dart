import 'recipe_ingredient.dart';
import 'recipe_scope.dart';

/// What one dish consumes: a scope and the ingredient lines configured for it.
///
/// ## Why there is no recipe row in the database
///
/// A recipe has no attributes of its own. It has no name — it is named by the dish —
/// no price, and no state. It is exactly its ingredient lines, so it is stored as
/// exactly its ingredient lines, each carrying the scope it belongs to. This type is
/// the assembled view of those rows, built by the repository.
///
/// The consequence is worth stating plainly, because the inventory screen depends on
/// it: an unconfigured recipe and an empty recipe are the same thing. There is no way
/// to create a recipe that exists but lists nothing, and therefore no way for the
/// screen to show "configured" for a dish that would deduct nothing. [isConfigured] is
/// the honest answer to "does this dish know what it uses".
class Recipe {
  Recipe({required this.scope, required List<RecipeIngredient> ingredients})
    : ingredients = List<RecipeIngredient>.unmodifiable(ingredients);

  /// A dish with nothing configured yet.
  Recipe.empty(this.scope) : ingredients = const <RecipeIngredient>[];

  /// The dish, or the size of the dish, these ingredients are for.
  final RecipeScope scope;

  /// The ingredient lines. Unmodifiable.
  final List<RecipeIngredient> ingredients;

  /// True when this dish has at least one ingredient, and so will deduct stock when
  /// it is sold.
  bool get isConfigured => ingredients.isNotEmpty;

  int get ingredientCount => ingredients.length;

  /// The stock items this dish uses.
  Set<String> get inventoryItemIds => ingredients
      .map((RecipeIngredient ingredient) => ingredient.inventoryItemId)
      .toSet();

  /// The line for [inventoryItemId], or `null` when this dish does not use it.
  ///
  /// At most one line per stock item exists within a scope; the schema enforces it
  /// with a partial unique index, and the repository refuses a duplicate with a
  /// message before the constraint has to.
  RecipeIngredient? lineFor(String inventoryItemId) {
    for (final RecipeIngredient ingredient in ingredients) {
      if (ingredient.inventoryItemId == inventoryItemId) {
        return ingredient;
      }
    }
    return null;
  }

  bool uses(String inventoryItemId) => lineFor(inventoryItemId) != null;

  @override
  String toString() => 'Recipe($scope, $ingredientCount ingredients)';
}
