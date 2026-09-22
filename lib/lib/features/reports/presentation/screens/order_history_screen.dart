import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../orders/presentation/widgets/bill_detail_view.dart';
import '../../../printing/domain/print_timestamp.dart';
import '../../domain/models/report_period.dart';
import '../../domain/models/sales_bill.dart';
import '../../domain/repositories/sales_report_repository.dart';
import '../controllers/order_history_controller.dart';
import '../widgets/report_notices.dart';

/// Finding a settled bill after the fact.
///
/// ## What it answers
///
/// "Where is that bill?" — by its number, by the customer's phone, by a date, by the kind
/// of order, or any combination. It is the counter's way back to a bill once it has left the
/// kitchen board, which is why it lives here rather than replacing the Orders section: the
/// Orders section is the live kitchen, and this is history.
///
/// ## Where the rows come from
///
/// [SalesReportRepository.searchBills], one indexed query. Every result is a settled bill,
/// carrying the same figures the reports show. Tapping one opens the same stored-document
/// view the reports and the customer history use, so a bill found here can be reprinted,
/// refunded or read exactly as anywhere else — and it shows what the customer was charged,
/// never today's prices.
class OrderHistoryScreen extends StatelessWidget {
  const OrderHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order history')),
      body: ChangeNotifierProvider<OrderHistoryController>(
        create: (BuildContext context) {
          final OrderHistoryController controller = OrderHistoryController(
            reportRepository: context.read<SalesReportRepository>(),
          );
          unawaited(controller.load());
          return controller;
        },
        child: const _OrderHistoryBody(),
      ),
    );
  }
}

class _OrderHistoryBody extends StatefulWidget {
  const _OrderHistoryBody();

  @override
  State<_OrderHistoryBody> createState() => _OrderHistoryBodyState();
}

class _OrderHistoryBodyState extends State<_OrderHistoryBody> {
  final TextEditingController _orderNumber = TextEditingController();
  final TextEditingController _phone = TextEditingController();

  @override
  void dispose() {
    _orderNumber.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final OrderHistoryController controller = context
        .watch<OrderHistoryController>();

    return Column(
      children: <Widget>[
        _SearchControls(
          controller: controller,
          orderNumberField: _orderNumber,
          phoneField: _phone,
        ),
        const Divider(height: 1),
        Expanded(child: _Results(controller: controller)),
      ],
    );
  }
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.controller,
    required this.orderNumberField,
    required this.phoneField,
  });

  final OrderHistoryController controller;
  final TextEditingController orderNumberField;
  final TextEditingController phoneField;

  void _submit() => unawaited(controller.search());

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: orderNumberField,
                  onChanged: controller.setOrderNumber,
                  onSubmitted: (String _) => _submit(),
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Bill number',
                    prefixIcon: Icon(Icons.receipt_long_outlined),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: phoneField,
                  onChanged: controller.setCustomerPhone,
                  onSubmitted: (String _) => _submit(),
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Customer phone',
                    prefixIcon: Icon(Icons.phone_outlined),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: controller.isLoading ? null : _submit,
                icon: const Icon(Icons.search),
                label: const Text('Search'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final ReportPeriod? option in OrderHistoryController.periods)
                ChoiceChip(
                  label: Text(_periodLabel(option)),
                  selected: option == controller.period,
                  onSelected: (bool _) =>
                      unawaited(controller.selectPeriod(option)),
                ),
              const SizedBox(width: 8),
              _OrderTypeFilter(controller: controller),
            ],
          ),
        ],
      ),
    );
  }

  static String _periodLabel(ReportPeriod? period) =>
      period?.label ?? 'Any date';
}

/// The order-type filter, "Any" plus each kind, as a dropdown to keep the chip row short.
class _OrderTypeFilter extends StatelessWidget {
  const _OrderTypeFilter({required this.controller});

  final OrderHistoryController controller;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<OrderType?>(
      value: controller.orderType,
      hint: const Text('Any type'),
      onChanged: (OrderType? value) =>
          unawaited(controller.selectOrderType(value)),
      items: <DropdownMenuItem<OrderType?>>[
        const DropdownMenuItem<OrderType?>(child: Text('Any type')),
        for (final OrderType type in OrderType.values)
          DropdownMenuItem<OrderType?>(value: type, child: Text(type.label)),
      ],
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final OrderHistoryController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const ReportLoadingView();
    }

    if (controller.hasError) {
      return ReportErrorView(
        message: controller.errorMessage!,
        onRetry: () => unawaited(controller.retry()),
      );
    }

    if (controller.isEmpty) {
      return const ReportEmptyView(
        icon: Icons.search_off_outlined,
        title: 'No bills match this search',
        message:
            'Try a different bill number, phone, date or order type. Only '
            'settled bills appear here; cancelled bills are not sales.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: controller.results.length,
      itemBuilder: (BuildContext context, int index) =>
          _HistoryRow(bill: controller.results[index]),
    );
  }
}

/// One matching bill. Tapping it opens the stored document.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.bill});

  final SalesBill bill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => BillDetailView.show(context, orderId: bill.orderId),
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Bill ${bill.orderNumber}',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(bill.total.formatted, style: theme.textTheme.titleSmall),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              _meta(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(_who(), style: theme.textTheme.bodySmall),
            if (bill.isRefunded) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                'Refunded ${bill.refundedAmount.formatted}  ·  net '
                '${bill.netTotal.formatted}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }

  String _meta() {
    return <String>[
      PrintTimestamp.stamp(bill.placedAt),
      bill.orderType.label,
      if (bill.paymentMethod != null) bill.paymentMethod!.label,
      if (bill.kotNumber != null) 'KOT ${bill.kotNumber}',
    ].join('  ·  ');
  }

  String _who() {
    final String? name = bill.customerName?.trim();
    final String? phone = bill.customerPhone;
    final bool hasName = name != null && name.isNotEmpty;
    final bool hasPhone = phone != null && phone.trim().isNotEmpty;
    if (hasName && hasPhone) {
      return '$name  ·  ${CustomerPhone.forDisplay(phone)}';
    }
    if (hasName) {
      return name;
    }
    if (hasPhone) {
      return CustomerPhone.forDisplay(phone);
    }
    return 'Walk-in';
  }
}
