import 'package:flutter/material.dart';

import '../../features/auth/presentation/widgets/auth_gate.dart';
import '../../features/billing/presentation/screens/checkout_screen.dart';
import '../../features/billing/presentation/screens/held_bills_screen.dart';
import '../../features/reports/presentation/screens/order_history_screen.dart';

/// Named routes for screens that open on top of the shell.
///
/// Top-level sections are not routes. They are swapped inside the persistent
/// shell so the navigation frame never rebuilds. Routes are reserved for
/// full-screen flows pushed over the shell, such as bill settlement or a report
/// detail view. Those entries are added as the modules are built.
class AppRoutes {
  const AppRoutes._();

  /// Entry point of the application. Resolves to the [AuthGate], which shows the login
  /// screen or the till depending on whether the terminal is signed in.
  static const String home = '/';

  /// Bill settlement, pushed over the shell.
  ///
  /// A route rather than a shell section: the billing screen stays as it was
  /// underneath, and the cashier can step back out of settlement without having
  /// committed anything. The screen takes the cart from the billing controller when
  /// it is pushed, so the route carries no arguments.
  static const String checkout = '/checkout';

  /// The bills put aside at the counter, pushed over the shell.
  ///
  /// A route rather than a shell section for the same reason as [checkout]: the billing
  /// screen stays as it was underneath, and resuming a bill returns to it with the bill in
  /// the cart. The screen reads the held bills for itself, so the route carries no
  /// arguments.
  static const String heldBills = '/held-bills';

  /// The order-history search, pushed over the shell.
  ///
  /// A route rather than a shell section, for the same reason as [checkout] and
  /// [heldBills]: it is a full-screen flow opened from the dashboard, and the section the
  /// operator was on — the kitchen board, most often — stays underneath. The Orders section
  /// remains the live kitchen; this is where a settled bill is found after the fact. The
  /// screen reads the bills for itself, so the route carries no arguments.
  static const String orderHistory = '/order-history';

  static Map<String, WidgetBuilder> routes() {
    return <String, WidgetBuilder>{
      home: (BuildContext context) => const AuthGate(),
      checkout: (BuildContext context) => const CheckoutScreen(),
      heldBills: (BuildContext context) => const HeldBillsScreen(),
      orderHistory: (BuildContext context) => const OrderHistoryScreen(),
    };
  }

  /// Fallback for an unregistered route name. Reaching this is a programming
  /// error, so it says so rather than silently showing a blank page.
  static Route<void> onUnknownRoute(RouteSettings settings) {
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Navigation error')),
        body: Center(
          child: Text('No route registered for "${settings.name}".'),
        ),
      ),
    );
  }
}
