import 'package:flutter/material.dart';

/// A repository failure, rendered in place rather than thrown.
///
/// A storage fault on a till is an operational condition, not a crash: whoever is at the
/// counter needs to read what went wrong and be able to try again. The same banner serves
/// the customer list and the history pane so a failure looks identical wherever it
/// happens.
class CustomerErrorBanner extends StatelessWidget {
  const CustomerErrorBanner({
    required this.message,
    required this.onRetry,
    this.onDismiss,
    super.key,
  });

  final String message;

  final VoidCallback onRetry;

  /// Omitted where there would be nothing usable left behind the banner.
  final VoidCallback? onDismiss;

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
          if (onDismiss != null)
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

/// An honest empty state: what is missing, and what to do about it.
///
/// Deliberately never shows an example. A customer list with a greyed-out
/// "98765 43210, 4 orders" would be indistinguishable from a real one at a glance, and
/// somebody would eventually read a figure off it.
class CustomerEmptyState extends StatelessWidget {
  const CustomerEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;

  final String title;

  final String message;

  final Widget? action;

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
              Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
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
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
