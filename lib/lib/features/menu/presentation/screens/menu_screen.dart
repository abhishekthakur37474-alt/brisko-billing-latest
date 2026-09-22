import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/repositories/menu_repository.dart';
import '../controllers/menu_management_controller.dart';
import '../widgets/category_management_view.dart';
import '../widgets/item_management_view.dart';
import '../widgets/option_management_view.dart';
import '../widgets/variant_management_view.dart';

/// Maintenance of the menu the outlet sells: categories, items, sizes and options.
///
/// ## One controller, four tabs
///
/// The four tabs edit the same subject — the menu — and share a single
/// [MenuManagementController], so a change on one tab is reflected on the others
/// without a reload. Categories are needed by the items tab, items by the sizes and
/// options tabs, and so on, which is why they are loaded together rather than per tab.
///
/// ## Nothing here is sample data
///
/// Every row on every tab comes from the database, through the repository. A freshly
/// installed terminal shows the seeded menu; an empty menu says it is empty and offers
/// to add the first row.
///
/// ## What it does not do
///
/// It does not price a bill, hold a cart, or delete history. Turning an item off hides
/// it from billing but leaves its past sales and its recipe intact, and a new price
/// changes only bills settled from now on. Those guarantees live in the controller and
/// the repository, not here.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<MenuManagementController>(
      create: (BuildContext context) {
        final MenuManagementController controller = MenuManagementController(
          menuRepository: context.read<MenuRepository>(),
        );
        // Not awaited: the first frame renders the loading state while the read runs.
        unawaited(controller.load());
        return controller;
      },
      child: const _MenuManagementBody(),
    );
  }
}

/// Which tab of the menu-management screen is showing.
enum _MenuTab {
  categories(label: 'Categories', icon: Icons.category_outlined),
  items(label: 'Items', icon: Icons.local_pizza_outlined),
  variants(label: 'Sizes', icon: Icons.straighten_outlined),
  options(label: 'Options', icon: Icons.tune);

  const _MenuTab({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class _MenuManagementBody extends StatefulWidget {
  const _MenuManagementBody();

  @override
  State<_MenuManagementBody> createState() => _MenuManagementBodyState();
}

class _MenuManagementBodyState extends State<_MenuManagementBody> {
  _MenuTab _tab = _MenuTab.categories;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_MenuTab>(
              segments: <ButtonSegment<_MenuTab>>[
                for (final _MenuTab tab in _MenuTab.values)
                  ButtonSegment<_MenuTab>(
                    value: tab,
                    label: Text(tab.label),
                    icon: Icon(tab.icon),
                  ),
              ],
              selected: <_MenuTab>{_tab},
              onSelectionChanged: (Set<_MenuTab> selection) {
                setState(() => _tab = selection.first);
              },
            ),
          ),
        ),
        Expanded(
          child: switch (_tab) {
            _MenuTab.categories => const CategoryManagementView(),
            _MenuTab.items => const ItemManagementView(),
            _MenuTab.variants => const VariantManagementView(),
            _MenuTab.options => const OptionManagementView(),
          },
        ),
      ],
    );
  }
}
