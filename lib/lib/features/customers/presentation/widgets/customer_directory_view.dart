import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../domain/models/customer_phone.dart';
import '../../domain/models/customer_summary.dart';
import '../controllers/customer_directory_controller.dart';
import 'customer_notices.dart';

/// The customer list: who is on file, their number, and what their bills add up to.
///
/// Reads [CustomerDirectoryController] and nothing else. There is no SQL here and no
/// arithmetic on a total; a row on screen is a row that was stored and a figure on it was
/// aggregated from stored bills.
class CustomerDirectoryView extends StatelessWidget {
  const CustomerDirectoryView({
    required this.selectedCustomerId,
    required this.onSelect,
    super.key,
  });

  /// The customer whose history is open, or `null`.
  final String? selectedCustomerId;

  final ValueChanged<CustomerSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    final CustomerDirectoryController controller = context
        .watch<CustomerDirectoryController>();

    return Column(
      children: <Widget>[
        _DirectoryHeader(controller: controller),
        if (controller.hasError)
          CustomerErrorBanner(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
            onDismiss: controller.dismissError,
          ),
        Expanded(
          child: _DirectoryBody(
            controller: controller,
            selectedCustomerId: selectedCustomerId,
            onSelect: onSelect,
          ),
        ),
      ],
    );
  }
}

class _DirectoryHeader extends StatelessWidget {
  const _DirectoryHeader({required this.controller});

  final CustomerDirectoryController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Customers', style: theme.textTheme.titleLarge),
              ),
              if (controller.isLoading)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              TextButton.icon(
                onPressed: controller.isLoading ? null : controller.refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _SearchField(),
        ],
      ),
    );
  }
}

/// Phone-number search.
///
/// The controller owns the query, so this holds only the text field. Filtering happens in
/// the database on every change, which is what makes the list narrow as somebody types
/// a number out.
class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: context.read<CustomerDirectoryController>().query,
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CustomerDirectoryController controller = context
        .watch<CustomerDirectoryController>();

    if (_field.text != controller.query) {
      _field.value = TextEditingValue(
        text: controller.query,
        selection: TextSelection.collapsed(offset: controller.query.length),
      );
    }

    return TextField(
      controller: _field,
      keyboardType: TextInputType.phone,
      decoration: InputDecoration(
        labelText: 'Search by phone number',
        hintText: 'Digits, or part of a name',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: controller.hasQuery
            ? IconButton(
                onPressed: controller.clearSearch,
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
              )
            : null,
      ),
      onChanged: controller.search,
    );
  }
}

class _DirectoryBody extends StatelessWidget {
  const _DirectoryBody({
    required this.controller,
    required this.selectedCustomerId,
    required this.onSelect,
  });

  final CustomerDirectoryController controller;

  final String? selectedCustomerId;

  final ValueChanged<CustomerSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.isEmptyDirectory) {
      return const CustomerEmptyState(
        icon: Icons.people_outline,
        title: 'No customers yet',
        message:
            'A customer is recorded when a phone number is entered at checkout. '
            'Nobody has given one on this terminal yet.',
      );
    }

    if (controller.isEmpty) {
      return CustomerEmptyState(
        icon: Icons.search_off,
        title: controller.isUnknownNumber
            ? 'That number has not ordered here'
            : 'No customer matches that',
        message: controller.isUnknownNumber
            ? 'There is no record for it yet. One is created the first time a '
                  'bill is settled against it at checkout.'
            : 'Try a different number, or part of a name.',
        action: TextButton(
          onPressed: controller.clearSearch,
          child: const Text('Clear search'),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: controller.results.length,
      itemBuilder: (BuildContext context, int index) {
        final CustomerSummary summary = controller.results[index];
        return _CustomerRow(
          summary: summary,
          isSelected: summary.id == selectedCustomerId,
          onTap: () => onSelect(summary),
        );
      },
    );
  }
}

/// One customer.
class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    required this.summary,
    required this.isSelected,
    required this.onTap,
  });

  final CustomerSummary summary;

  final bool isSelected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? name = summary.customer.name?.trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isSelected ? theme.colorScheme.secondaryContainer : null,
      child: ListTile(
        onTap: onTap,
        selected: isSelected,
        title: Text(
          name == null || name.isEmpty
              ? CustomerPhone.forDisplay(summary.phone)
              : name,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          _subtitle(name),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            // In words as well as figures. "4 orders" cannot be misread as an amount.
            Text(
              summary.completedOrderCount == 1
                  ? '1 order'
                  : '${summary.completedOrderCount} orders',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 2),
            Text(
              summary.totalSpent.formatted,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The phone number, and when they last came in.
  ///
  /// Says "No bills yet" rather than showing a date that does not exist. A record can
  /// legitimately have nothing against it.
  String _subtitle(String? name) {
    final DateTime? last = summary.lastOrderAt;
    final String visit = last == null
        ? 'No bills yet'
        : 'Last bill ${PrintTimestamp.stamp(last)}';
    final String number = CustomerPhone.forDisplay(summary.phone);
    return name == null || name.isEmpty ? visit : '$number  ·  $visit';
  }
}
