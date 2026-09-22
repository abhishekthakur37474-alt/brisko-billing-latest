import 'package:flutter/material.dart';

/// The top-level areas of the POS reachable from the persistent navigation.
///
/// This enum carries navigation metadata only. It intentionally does not know
/// which widget renders each section; that mapping lives in the shell, so feature
/// modules stay decoupled from this file.
enum PosSection {
  dashboard(
    label: 'Dashboard',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard,
  ),
  billing(
    label: 'New Bill',
    icon: Icons.point_of_sale_outlined,
    selectedIcon: Icons.point_of_sale,
  ),
  orders(
    label: 'Orders',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
  ),
  menu(
    label: 'Menu',
    icon: Icons.local_pizza_outlined,
    selectedIcon: Icons.local_pizza,
  ),
  inventory(
    label: 'Inventory',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
  ),
  customers(
    label: 'Customers',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
  ),
  reports(
    label: 'Reports',
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
  ),
  expenses(
    label: 'Expenses',
    icon: Icons.attach_money_outlined,
    selectedIcon: Icons.attach_money,
  ),
  manager(
    label: 'Manager',
    icon: Icons.admin_panel_settings_outlined,
    selectedIcon: Icons.admin_panel_settings,
  ),
  settings(
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  );

  const PosSection({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// Text shown in the navigation rail and in the app bar.
  final String label;

  final IconData icon;

  final IconData selectedIcon;
}
