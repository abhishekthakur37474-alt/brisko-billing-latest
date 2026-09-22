import '../../../../core/utils/result.dart';
import '../models/recipe.dart';
import '../models/recipe_ingredient.dart';
import '../models/recipe_scope.dart';

/// Read and write access to the link between a dish and the stock it consumes.
///
/// ## Why this lives in the inventory feature
///
/// A recipe touches the menu and the inventory, so it could plausibly belong to
/// either. It is here because it exists for one purpose: to tell the stock ledger what
/// to take off the shelf when something is sold. Nothing in the menu, in billing or on
/// a receipt reads a recipe. Keeping it beside the deduction that consumes it means the
/// two cannot drift apart, and it keeps the menu module unaware that inventory exists.
///
/// ## Every write is immediate
///
/// There is no draft and no bulk save. Adding, repricing or removing an ingredient is
/// persisted as it is done, so an admin who is interrupted mid-edit at a till has lost
/// nothing and a half-configured recipe is a real, visible state rather than unsaved
/// work. That is also why the granular operations are the contract rather than a
/// "replace the whole recipe" call, which could silently discard a line the operator
/// had not looked at.
abstract interface class RecipeRepository {
  /// The recipe configured for [scope] exactly, without falling back.
  ///
  /// Returns an empty [Recipe] rather than `null` when nothing is configured, because
  /// "this dish uses nothing yet" is a real answer the screen has to render. Does not
  /// resolve [RecipeScope.fallback]: the recipe screen is editing one scope and must
  /// show what that scope holds, not what a sale would end up using.
  Future<Result<Recipe>> loadRecipe(RecipeScope scope);

  /// The recipe a sale of [scope] would actually consume.
  ///
  /// Applies the fallback: a size with its own recipe uses it, a size without one
  /// uses the product-level recipe, and a dish with neither returns an empty recipe.
  /// This is the resolution the deduction performs, exposed so the recipe screen can
  /// tell the operator which recipe a size will really use.
  Future<Result<Recipe>> resolveRecipe(RecipeScope scope);

  /// Every ingredient line belonging to one product, across all of its sizes.
  Future<Result<List<RecipeIngredient>>> loadIngredientsForMenuItem(
    String menuItemId,
  );

  /// Ids of the products that have at least one ingredient configured, at product
  /// level or on any of their sizes.
  ///
  /// Drives the "configured" marker in the recipe list, so the operator can see at a
  /// glance what is still outstanding without opening every dish.
  Future<Result<Set<String>>> loadConfiguredMenuItemIds();

  /// Adds an ingredient to [scope].
  ///
  /// Returns a [ValidationFailure] when [quantityMilli] is not positive, when
  /// [inventoryItemId] names no live stock item, when [scope] names no live menu item
  /// or size, or when this scope already uses that stock item. A duplicate is refused
  /// rather than merged, because two lines for cheese would have to be added together
  /// to know what a pizza uses, and nobody reading the screen would expect that.
  Future<Result<RecipeIngredient>> addIngredient({
    required RecipeScope scope,
    required String inventoryItemId,
    required int quantityMilli,
  });

  /// Changes how much of one ingredient the dish uses.
  ///
  /// Returns a [ValidationFailure] when [quantityMilli] is not positive, or when the
  /// line does not exist. Deducting nothing is not a recipe line; removing the
  /// ingredient is the way to say the dish stopped using it.
  Future<Result<void>> updateIngredientQuantity({
    required String ingredientId,
    required int quantityMilli,
  });

  /// Removes an ingredient from its recipe.
  ///
  /// Soft delete, like everything else. Bills already deducted are unaffected: what
  /// came off the shelf is in the stock ledger, not here.
  Future<Result<void>> removeIngredient(String ingredientId);

  /// True when at least one live recipe line consumes [inventoryItemId].
  ///
  /// Used to refuse deleting a stock item that something still uses, which would
  /// otherwise turn every later sale of that dish into a failed deduction.
  Future<Result<bool>> isInventoryItemInUse(String inventoryItemId);
}
