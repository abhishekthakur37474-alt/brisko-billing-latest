import 'package:flutter/material.dart';

/// A repository failure on the menu-management screen, rendered in place.
///
/// A storage fault while editing the menu is an operational condition, not a crash:
/// the owner needs to read what went wrong and try again. The same banner serves all
/// four tabs so a failure looks identical wherever it happens.
class MenuErrorBanner extends StatelessWidget {
  const MenuErrorBanner({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
    super.key,
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

/// An honest empty state: what is missing, and what to do about it.
///
/// Never shows an example row. A greyed-out sample item would be indistinguishable
/// from a real one at a glance, and no product data belongs anywhere but the seed and
/// what the owner enters.
class MenuEmptyState extends StatelessWidget {
  const MenuEmptyState({
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
          constraints: const BoxConstraints(maxWidth: 440),
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

/// The badge shown beside a switched-off or out-of-stock row.
///
/// The word, not just a colour: a colour alone is invisible to anyone who cannot
/// distinguish it.
class MenuStateChip extends StatelessWidget {
  const MenuStateChip({
    required this.label,
    this.tone = MenuChipTone.neutral,
    super.key,
  });

  final String label;

  final MenuChipTone tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (Color background, Color foreground) = switch (tone) {
      MenuChipTone.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
      MenuChipTone.warning => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      MenuChipTone.error => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

enum MenuChipTone { neutral, warning, error }
