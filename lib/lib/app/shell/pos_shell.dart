import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../features/auth/presentation/screens/manager_password_screen.dart';
import '../../features/billing/presentation/screens/billing_screen.dart';
import '../../features/cloud_sync/presentation/widgets/sync_status_indicator.dart';
import '../../features/customers/presentation/screens/customers_screen.dart';
import '../../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../../features/expenses/presentation/screens/expenses_screen.dart';
import '../../features/inventory/presentation/screens/inventory_screen.dart';
import '../../features/kot/presentation/screens/kitchen_screen.dart';
import '../../features/menu/presentation/screens/menu_screen.dart';
import '../../features/printing/domain/models/business_identity.dart';
import '../../features/reports/presentation/screens/reports_screen.dart';
import '../../features/settings/domain/active_pos_settings.dart';
import '../../features/settings/domain/models/pos_settings.dart';
import '../../features/settings/presentation/screens/settings_screen.dart';
import 'pos_section.dart';
import 'shell_controller.dart';

/// Persistent frame around the POS: navigation plus the active section.
///
/// The shell is the only place that knows which widget belongs to which
/// [PosSection]. Feature modules expose a screen and nothing else, so adding or
/// replacing a module touches this one mapping.
class PosShell extends StatelessWidget {
  const PosShell({super.key});

  @override
  Widget build(BuildContext context) {
    final PosSection section = context.select<ShellController, PosSection>(
      (ShellController controller) => controller.section,
    );

    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    // The outlet's own trading name, taken from the configuration the bootstrap loaded
    // and the Settings screen updates — never hard-coded. It falls back to the same
    // BusinessIdentity.defaultName the receipt header uses, so the screen and the paper
    // lead with the same name. read (not watch): ActivePosSettings is replaced wholesale
    // on save, and the shell rebuilds on the next navigation, which is when a renamed
    // outlet should appear in the frame.
    final PosSettings settings = context.read<ActivePosSettings>().settings;
    final String outletName = settings.businessName ?? BusinessIdentity.defaultName;

    return Scaffold(
      appBar: AppBar(
        title: _ShellTitle(outletName: outletName, sectionLabel: section.label),
        // Unobtrusive, and never a control: the sync status reports here, while
        // the manual sync and detail live in Settings.
        actions: const <Widget>[
          Center(child: SyncStatusIndicator()),
          SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: <Widget>[
          if (isWide) ...<Widget>[
            _ShellNavigationRail(section: section),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: _sectionScreen(section)),
        ],
      ),
      bottomNavigationBar: isWide
          ? null
          : _ShellNavigationBar(section: section),
    );
  }

  /// Maps a navigation section to the screen that renders it.
  static Widget _sectionScreen(PosSection section) {
    return switch (section) {
      PosSection.dashboard => const DashboardScreen(),
      PosSection.billing => const BillingScreen(),
      // The Orders section is the kitchen board. For this outlet, what the counter
      // needs from a settled order is what the kitchen still has to make; bill
      // history, reprinting and refunds are separate later work.
      PosSection.orders => const KitchenScreen(),
      PosSection.menu => const MenuScreen(),
      PosSection.inventory => const InventoryScreen(),
      PosSection.customers => const CustomersScreen(),
      PosSection.reports => const ReportsScreen(),
      PosSection.expenses => const ExpensesScreen(),
      PosSection.manager => const ManagerPasswordScreen(),
      PosSection.settings => const SettingsScreen(),
    };
  }
}

/// The app bar heading: the outlet's name, with the active section beneath it.
///
/// The name is the branding the requirement asks for, shown prominently in the frame that
/// stays on screen through every section. It is the configured business name, so a
/// differently named outlet sees its own name here; the section label keeps the operator
/// oriented without a separate title bar.
class _ShellTitle extends StatelessWidget {
  const _ShellTitle({required this.outletName, required this.sectionLabel});

  final String outletName;
  final String sectionLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          outletName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          sectionLabel,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Side navigation for tablet and desktop layouts.
///
/// A custom rail rather than [NavigationRail]: ten labelled destinations do not
/// always fit a short counter window, and [NavigationRail] overflows instead of
/// scrolling. This list scrolls when it must, and keeps the same icon-above-label
/// layout the operator already knows.
class _ShellNavigationRail extends StatelessWidget {
  const _ShellNavigationRail({required this.section});

  static const double _width = 88;

  final PosSection section;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colours = Theme.of(context).colorScheme;

    return Material(
      color: colours.surface,
      child: SizedBox(
        width: _width,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: <Widget>[
            for (final PosSection item in PosSection.values)
              _RailDestination(
                item: item,
                selected: item == section,
                onTap: () => context.read<ShellController>().select(item),
              ),
          ],
        ),
      ),
    );
  }
}

/// One destination in the side rail: icon, then the section label.
class _RailDestination extends StatelessWidget {
  const _RailDestination({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final PosSection item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colours = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: kThemeAnimationDuration,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? colours.secondaryContainer : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                selected ? item.selectedIcon : item.icon,
                color: selected
                    ? colours.onSecondaryContainer
                    : colours.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected
                    ? colours.onSurface
                    : colours.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom navigation for narrow layouts.
///
/// `NavigationBar` is not designed for eight destinations, so the narrow layout
/// shows the sections used during a shift and reaches the rest through the
/// "More" sheet.
class _ShellNavigationBar extends StatelessWidget {
  const _ShellNavigationBar({required this.section});

  static const List<PosSection> _primary = <PosSection>[
    PosSection.dashboard,
    PosSection.billing,
    PosSection.orders,
  ];

  final PosSection section;

  @override
  Widget build(BuildContext context) {
    final int selectedIndex = _primary.indexOf(section);

    return NavigationBar(
      // When a secondary section is active, no primary destination is
      // highlighted, so "More" is shown as selected instead.
      selectedIndex: selectedIndex == -1 ? _primary.length : selectedIndex,
      onDestinationSelected: (int index) {
        if (index < _primary.length) {
          context.read<ShellController>().select(_primary[index]);
        } else {
          _showMoreSections(context);
        }
      },
      destinations: <Widget>[
        for (final PosSection item in _primary)
          NavigationDestination(
            icon: Icon(item.icon),
            selectedIcon: Icon(item.selectedIcon),
            label: item.label,
          ),
        const NavigationDestination(
          icon: Icon(Icons.more_horiz),
          label: 'More',
        ),
      ],
    );
  }

  Future<void> _showMoreSections(BuildContext context) async {
    final ShellController controller = context.read<ShellController>();

    final PosSection? chosen = await showModalBottomSheet<PosSection>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final PosSection item in PosSection.values)
                if (!_primary.contains(item))
                  ListTile(
                    leading: Icon(
                      item == section ? item.selectedIcon : item.icon,
                    ),
                    title: Text(item.label),
                    selected: item == section,
                    onTap: () => Navigator.of(sheetContext).pop(item),
                  ),
            ],
          ),
        );
      },
    );

    if (chosen != null) {
      controller.select(chosen);
    }
  }
}
