import 'package:flutter/material.dart';

import '../../domain/models/kitchen_ticket.dart';
import '../../domain/models/kitchen_ticket_time.dart';

/// One kitchen slip, as the kitchen reads it.
///
/// Shows the order number, how the order leaves the counter, the time it was raised,
/// and every line with its size, its customisations and its quantity. No prices: the
/// kitchen is being told what to cook.
///
/// Every string here comes from the slip's own snapshot columns. Nothing on this card
/// is looked up in the menu, so a card rendered today and the same card rendered after
/// the menu is renamed read identically.
class KitchenTicketCard extends StatelessWidget {
  const KitchenTicketCard({
    required this.ticket,
    required this.onAdvance,
    this.isAdvancing = false,
    super.key,
  });

  final KitchenTicket ticket;

  /// Moves the slip to its next state. Null when there is no forward move.
  final VoidCallback? onAdvance;

  /// True while this slip's move is being written, so its button is disabled without
  /// locking the rest of the board.
  final bool isAdvancing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? advanceLabel = ticket.status.advanceLabel;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    ticket.orderNumber,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  KitchenTicketTime.clock(ticket.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Chip(
                  label: Text(ticket.orderType.label),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 8),
                Text(
                  ticket.kotNumber,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            for (final KitchenTicketLine line in ticket.lines)
              _TicketLine(line: line),
            if (ticket.hasNotes) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                ticket.notes!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (advanceLabel != null) ...<Widget>[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: isAdvancing ? null : onAdvance,
                  child: Text(advanceLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One line of a slip: what to make, how many, and what to change about it.
class _TicketLine extends StatelessWidget {
  const _TicketLine({required this.line});

  final KitchenTicketLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Quantity first and fixed width, so a stack of slips can be read down
          // the column without hunting for the number.
          SizedBox(
            width: 36,
            child: Text(
              '\u00d7${line.quantity}',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(line.displayName, style: theme.textTheme.bodyLarge),
                if (line.hasOptions)
                  Text(
                    line.optionSummary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (line.notes != null && line.notes!.isNotEmpty)
                  Text(
                    line.notes!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
