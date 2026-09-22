import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../domain/models/held_bill.dart';
import '../../domain/models/held_bill_summary.dart';
import '../../domain/repositories/held_bill_repository.dart';
import '../controllers/billing_controller.dart';
import '../controllers/held_bills_controller.dart';

/// The bills put aside at the counter, with a way to bring one back or let it go.
///
/// ## Pushed over the shell, like checkout
///
/// A route rather than a section: it is reached from a button on the billing cart, it
/// changes the live cart, and the cashier steps back to the same billing screen they left.
/// The [BillingController] lives above the shell, so this screen reads it straight from the
/// tree to know whether a bill is already on screen and to hand a resumed cart back to it.
///
/// ## Resuming needs an empty counter
///
/// A resumed bill becomes the live cart, and there can only be one live cart. So Resume is
/// disabled while a bill is already on screen, with the reason shown rather than left to be
/// guessed at: the cashier holds or clears what they have first.
///
/// ## Every failure is rendered, never thrown
///
/// A read that fails shows a retry. A resume or cancel that fails shows its message and the
/// list reloads, because the usual cause is that the bill is gone from another terminal and
/// the reloaded list is the honest answer. Nothing here throws into the widget tree.
class HeldBillsScreen extends StatelessWidget {
  const HeldBillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<HeldBillsController>(
      create: (BuildContext context) {
        final HeldBillsController controller = HeldBillsController(
          heldBillRepository: context.read<HeldBillRepository>(),
        );
        // Not awaited: the first frame shows the loading state while the read runs.
        unawaited(controller.load());
        return controller;
      },
      child: const _HeldBillsView(),
    );
  }
}

class _HeldBillsView extends StatelessWidget {
  const _HeldBillsView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Held bills')),
      body: SafeArea(child: _Body()),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final HeldBillsController controller = context.watch<HeldBillsController>();

    if (!controller.hasLoaded) {
      return const _HeldBillsLoadingView();
    }

    if (controller.hasError) {
      return HeldBillsErrorView(
        message: controller.errorMessage!,
        onRetry: () => unawaited(controller.retry()),
      );
    }

    if (controller.isEmpty) {
      return const _HeldBillsEmptyView();
    }

    // A bill can only be resumed onto an empty counter, and the billing controller above
    // the shell is the one thing that knows whether a bill is already on screen.
    final bool canResume = context.select<BillingController, bool>(
      (BillingController billing) => billing.cart.isEmpty,
    );

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: controller.bills.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) {
        final HeldBillSummary summary = controller.bills[index];
        return _HeldBillCard(
          summary: summary,
          canResume: canResume,
          isBusy: controller.isBusy(summary.id),
        );
      },
    );
  }
}

/// One held bill: what it is, and the two things that can be done with it.
class _HeldBillCard extends StatelessWidget {
  const _HeldBillCard({
    required this.summary,
    required this.canResume,
    required this.isBusy,
  });

  final HeldBillSummary summary;

  /// False when a bill is already on screen, so this one cannot be resumed onto it.
  final bool canResume;

  /// True while this bill's own resume or cancel is being written.
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String customer = summary.hasCustomerPhone
        ? 'Customer ${summary.customerPhoneDisplay}'
        : 'Walk-in';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        summary.orderType.label,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary.countsLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        customer,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  summary.subtotal.formatted,
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: isBusy ? null : () => _confirmCancel(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: (!canResume || isBusy)
                      ? null
                      : () => _resume(context),
                  child: const Text('Resume'),
                ),
              ],
            ),
            if (!canResume) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Hold or clear the bill on screen to resume this one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Resumes the bill, and on success takes its cart back to the billing screen.
  Future<void> _resume(BuildContext context) async {
    final HeldBillsController controller = context.read<HeldBillsController>();
    final BillingController billing = context.read<BillingController>();
    final NavigatorState navigator = Navigator.of(context);

    final HeldBill? resumed = await controller.resume(summary.id);
    if (resumed == null) {
      // The failure is rendered by the reloaded list; if the bill is gone it simply is not
      // there any more. Nothing to pop for.
      return;
    }

    billing.adoptResumedBill(resumed);
    // Back to the billing screen the cashier came from, now with the bill in the cart.
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  /// Confirms before abandoning a held bill.
  Future<void> _confirmCancel(BuildContext context) async {
    final HeldBillsController controller = context.read<HeldBillsController>();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Cancel this held bill?'),
          content: const Text(
            'The bill will be abandoned and removed from this list. It is kept '
            'for the record and cannot be resumed afterwards.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep it'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Cancel the bill'),
            ),
          ],
        );
      },
    );

    if (confirmed ?? false) {
      await controller.cancel(summary.id);
    }
  }
}

/// The state between opening the screen and the list arriving.
///
/// A plain line rather than a spinner: reading the held bills is one query against a local
/// file, over before an animation could turn once, and a widget that animates forever is a
/// widget a test cannot settle.
class _HeldBillsLoadingView extends StatelessWidget {
  const _HeldBillsLoadingView();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Reading the held bills…',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// An honest empty state: nothing is being held, said plainly rather than as a blank list.
class _HeldBillsEmptyView extends StatelessWidget {
  const _HeldBillsEmptyView();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.pause_circle_outline,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'No bills are being held',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'A bill put aside from the counter appears here, ready to be '
              'resumed or cancelled.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the held bills could not be read, with the reason and a retry.
///
/// Names the held bills rather than the menu, because sending a cashier to look at the menu
/// over a held-bills fault would waste their time. The only way forward is the retry, so a
/// transient storage problem does not strand the list.
class HeldBillsErrorView extends StatelessWidget {
  const HeldBillsErrorView({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.error_outline,
                size: 40,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                'The held bills could not be loaded',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
