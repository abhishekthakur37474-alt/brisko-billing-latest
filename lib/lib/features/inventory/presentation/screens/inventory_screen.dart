import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../menu/domain/repositories/menu_repository.dart';
import '../../domain/repositories/inventory_deduction_repository.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../../domain/repositories/recipe_repository.dart';
import '../controllers/inventory_controller.dart';
import '../controllers/recipe_controller.dart';
import '../widgets/recipe_view.dart';
import '../widgets/stock_view.dart';

/// Stock tracking for the outlet: what is on the shelves, and what each dish uses.
///
/// ## Two halves, one screen
///
/// Stock and recipes are separate tasks with separate rhythms. Stock is touched daily,
/// by whoever takes a delivery or throws away a spoiled tray. Recipes are set up once
/// and corrected rarely, by the owner. They live behind one switch rather than two
/// navigation entries because they are the same subject — what the outlet consumes —
/// and because the shell's navigation is already eight items long.
///
/// ## Nothing here is sample data
///
/// Every row on both halves comes from the database. A freshly installed terminal shows
/// no stock items and no recipes, and says so.
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

/// Which half of the screen is showing.
enum _InventoryTab {
  stock(label: 'Stock', icon: Icons.inventory_2_outlined),
  recipes(label: 'Recipes', icon: Icons.menu_book_outlined);

  const _InventoryTab({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class _InventoryScreenState extends State<InventoryScreen> {
  _InventoryTab _tab = _InventoryTab.stock;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SegmentedButton<_InventoryTab>(
            segments: <ButtonSegment<_InventoryTab>>[
              for (final _InventoryTab tab in _InventoryTab.values)
                ButtonSegment<_InventoryTab>(
                  value: tab,
                  label: Text(tab.label),
                  icon: Icon(tab.icon),
                ),
            ],
            selected: <_InventoryTab>{_tab},
            onSelectionChanged: (Set<_InventoryTab> selection) {
              setState(() => _tab = selection.first);
            },
          ),
        ),
        Expanded(
          child: switch (_tab) {
            // Keyed so switching halves builds a fresh controller and reads current
            // data, rather than showing whatever was loaded when the operator last
            // looked. Balances change every time a bill is settled.
            _InventoryTab.stock => const _StockHalf(
              key: ValueKey<String>('stock'),
            ),
            _InventoryTab.recipes => const _RecipesHalf(
              key: ValueKey<String>('recipes'),
            ),
          },
        ),
      ],
    );
  }
}

/// The stock list, with its own controller.
class _StockHalf extends StatelessWidget {
  const _StockHalf({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<InventoryController>(
      create: (BuildContext context) {
        final InventoryController controller = InventoryController(
          inventoryRepository: context.read<InventoryRepository>(),
          deductionRepository: context.read<InventoryDeductionRepository>(),
        );
        // Deliberately not awaited: the first frame renders the loading state while
        // the read runs.
        unawaited(controller.load());
        return controller;
      },
      child: const StockView(),
    );
  }
}

/// The recipe editor, with its own controller.
class _RecipesHalf extends StatelessWidget {
  const _RecipesHalf({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<RecipeController>(
      create: (BuildContext context) {
        final RecipeController controller = RecipeController(
          menuRepository: context.read<MenuRepository>(),
          inventoryRepository: context.read<InventoryRepository>(),
          recipeRepository: context.read<RecipeRepository>(),
        );
        unawaited(controller.load());
        return controller;
      },
      child: const RecipeView(),
    );
  }
}
