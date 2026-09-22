import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../orders/domain/repositories/order_repository.dart';
import '../../../payments/domain/repositories/payment_repository.dart';
import '../../domain/models/customer_summary.dart';
import '../../domain/repositories/customer_repository.dart';
import '../controllers/customer_directory_controller.dart';
import '../controllers/customer_history_controller.dart';
import '../widgets/customer_directory_view.dart';
import '../widgets/customer_history_view.dart';
import '../widgets/customer_notices.dart';

/// Customer records, keyed by phone number, with the bills each has been given.
///
/// ## What this screen is for
///
/// One question, asked at a counter: somebody gives a number, and the cashier wants to
/// know what that person has ordered before. Everything on the screen serves it — search
/// by number, the totals for whoever is selected, their bills newest first, and any one
/// of those bills opened as the document it was.
///
/// ## Where the data comes from
///
/// The customer record comes from `customers`; the count, the spend and the last visit
/// are aggregated from `orders`; the history is the `orders` rows themselves, with their
/// stored line snapshots. Nothing is read from the menu, which is what keeps a bill from
/// six months ago correct after the menu has moved on.
///
/// A customer cannot be created here. They are created by settling a bill with a phone
/// number, because a customer with no bill is a record of nothing; the empty state says
/// so rather than offering an "Add customer" button that would invite made-up rows.
///
/// ## Layout
///
/// Two panes side by side on a billing tablet or desktop: the list on the left, the
/// selected customer on the right. On a narrow screen the list fills the width and a
/// customer opens over it, because two columns of eight-character phone numbers on a
/// phone is neither.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  /// The customer whose history is open, or `null`.
  ///
  /// Held here rather than in the directory controller: which record is being looked at
  /// is a fact about this screen, not about the list.
  String? _selectedCustomerId;

  @override
  Widget build(BuildContext context) {
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    return ChangeNotifierProvider<CustomerDirectoryController>(
      create: (BuildContext context) {
        final CustomerDirectoryController controller =
            CustomerDirectoryController(
              customerRepository: context.read<CustomerRepository>(),
            );
        // Deliberately not awaited: the first frame renders the loading state while the
        // read runs.
        unawaited(controller.load());
        return controller;
      },
      child: isWide ? _wide() : _narrow(),
    );
  }

  Widget _wide() {
    return Row(
      children: <Widget>[
        Expanded(flex: 2, child: _directory()),
        const VerticalDivider(width: 1),
        Expanded(flex: 3, child: _detailPane()),
      ],
    );
  }

  Widget _narrow() => _directory();

  Widget _directory() {
    return CustomerDirectoryView(
      selectedCustomerId: _selectedCustomerId,
      onSelect: _open,
    );
  }

  /// The right-hand pane: the open customer, or an invitation to pick one.
  Widget _detailPane() {
    final String? id = _selectedCustomerId;
    if (id == null) {
      return const CustomerEmptyState(
        icon: Icons.person_search_outlined,
        title: 'No customer selected',
        message:
            'Search for a phone number, then choose a customer to see the bills '
            'they have been given.',
      );
    }

    return CustomerHistoryScope(
      customerId: id,
      child: CustomerHistoryView(
        onClose: () => setState(() => _selectedCustomerId = null),
      ),
    );
  }

  /// Opens a customer: into the pane when there is one, otherwise over the list.
  void _open(CustomerSummary summary) {
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    if (isWide) {
      setState(() => _selectedCustomerId = summary.id);
      return;
    }

    setState(() => _selectedCustomerId = summary.id);
    unawaited(_showCustomerSheet(summary.id));
  }

  Future<void> _showCustomerSheet(String customerId) async {
    // Captured before the await so the sheet is built against the repositories this
    // screen was given, not against whatever is above the sheet's own context.
    final CustomerRepository customers = context.read<CustomerRepository>();
    final OrderRepository orders = context.read<OrderRepository>();
    final PaymentRepository payments = context.read<PaymentRepository>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: MultiProvider(
            providers: [
              Provider<CustomerRepository>.value(value: customers),
              Provider<OrderRepository>.value(value: orders),
              Provider<PaymentRepository>.value(value: payments),
            ],
            child: CustomerHistoryScope(
              customerId: customerId,
              child: const CustomerHistoryView(),
            ),
          ),
        );
      },
    );

    if (mounted) {
      setState(() => _selectedCustomerId = null);
    }
  }
}

/// Builds and loads a [CustomerHistoryController] for one customer.
///
/// Keyed on the customer id, so choosing a different customer builds a fresh controller
/// and reads their bills rather than showing the previous one's while the new read runs.
class CustomerHistoryScope extends StatelessWidget {
  const CustomerHistoryScope({
    required this.customerId,
    required this.child,
    super.key,
  });

  final String customerId;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<CustomerHistoryController>(
      key: ValueKey<String>(customerId),
      create: (BuildContext context) {
        final CustomerHistoryController controller = CustomerHistoryController(
          customerId: customerId,
          customerRepository: context.read<CustomerRepository>(),
          orderRepository: context.read<OrderRepository>(),
          paymentRepository: context.read<PaymentRepository>(),
        );
        unawaited(controller.load());
        return controller;
      },
      child: child,
    );
  }
}
