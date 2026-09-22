import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../domain/models/kitchen_ticket.dart';
import '../../domain/models/kot_status.dart';
import '../../domain/repositories/kot_repository.dart';
import '../controllers/kitchen_controller.dart';
import '../widgets/kitchen_ticket_card.dart';

/// The kitchen board: every slip the kitchen still has to deal with.
///
/// ## Where the data comes from
///
/// Persisted slips, read through [KotRepository]. There are no sample slips and no
/// placeholder rows; an outlet that has taken no orders sees an empty board, which is
/// the truthful thing to show.
///
/// ## Reloading
///
/// The controller is created here, and the shell rebuilds the active section's widget
/// on every navigation, so arriving at this section reads the board afresh. A refresh
/// action re-reads it on demand. That is sufficient while one terminal owns these
/// rows; a live cloud feed is a later concern.
class KitchenScreen extends StatelessWidget {
  const KitchenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<KitchenController>(
      create: (BuildContext context) {
        final KitchenController controller = KitchenController(
          kotRepository: context.read<KotRepository>(),
        );
        // Deliberately not awaited: the first frame renders the loading state while
        // the read runs.
        unawaited(controller.load());
        return controller;
      },
      child: const _KitchenView(),
    );
  }
}

class _KitchenView extends StatelessWidget {
  const _KitchenView();

  @override
  Widget build(BuildContext context) {
    final KitchenController controller = context.watch<KitchenController>();
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;

    return Column(
      children: <Widget>[
        _BoardHeader(controller: controller),
        if (controller.hasError)
          _BoardError(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
            onDismiss: controller.dismissError,
          ),
        Expanded(
          child: _BoardBody(controller: controller, isWide: isWide),
        ),
      ],
    );
  }
}

class _BoardHeader extends StatelessWidget {
  const _BoardHeader({required this.controller});

  final KitchenController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text('Kitchen slips', style: theme.textTheme.titleLarge),
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
    );
  }
}

/// A repository failure, rendered in place rather than thrown.
class _BoardError extends StatelessWidget {
  const _BoardError({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

class _BoardBody extends StatelessWidget {
  const _BoardBody({required this.controller, required this.isWide});

  final KitchenController controller;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.isEmpty) {
      return const _EmptyBoard();
    }

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final KotStatus status in KitchenController.boardStatuses)
            Expanded(
              child: _StatusColumn(controller: controller, status: status),
            ),
        ],
      );
    }

    // Narrow: one scrolling list with a heading per state, because three columns on a
    // phone-width window would be unreadable.
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: <Widget>[
        for (final KotStatus status in KitchenController.boardStatuses)
          ..._section(context, status),
      ],
    );
  }

  List<Widget> _section(BuildContext context, KotStatus status) {
    final List<KitchenTicket> tickets = controller.ticketsAt(status);
    return <Widget>[
      _ColumnHeading(status: status, count: tickets.length),
      if (tickets.isEmpty)
        const _ColumnEmpty()
      else
        for (final KitchenTicket ticket in tickets)
          KitchenTicketCard(
            ticket: ticket,
            isAdvancing: controller.isAdvancing(ticket.id),
            onAdvance: () => controller.advance(ticket),
          ),
    ];
  }
}

/// One state's worth of slips, newest at the top.
class _StatusColumn extends StatelessWidget {
  const _StatusColumn({required this.controller, required this.status});

  final KitchenController controller;
  final KotStatus status;

  @override
  Widget build(BuildContext context) {
    final List<KitchenTicket> tickets = controller.ticketsAt(status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _ColumnHeading(status: status, count: tickets.length),
        ),
        Expanded(
          child: tickets.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _ColumnEmpty(),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: <Widget>[
                    for (final KitchenTicket ticket in tickets)
                      KitchenTicketCard(
                        ticket: ticket,
                        isAdvancing: controller.isAdvancing(ticket.id),
                        onAdvance: () => controller.advance(ticket),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ColumnHeading extends StatelessWidget {
  const _ColumnHeading({required this.status, required this.count});

  final KotStatus status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Text(status.label, style: theme.textTheme.titleSmall),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnEmpty extends StatelessWidget {
  const _ColumnEmpty();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        'Nothing here.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard();

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
              Icons.receipt_long_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No kitchen slips', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A slip is raised for every bill that is settled.',
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
