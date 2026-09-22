import 'package:flutter/material.dart';

/// A repository failure, rendered where the report would have been.
///
/// A storage fault on a till is an operational condition, not a crash. Whoever is at the
/// counter needs to read what went wrong and be able to try again, and the rest of the
/// screen — the date filter, the tabs — has to keep working while they do. Nothing here
/// throws, and no figure is shown beside the message: a total the reader cannot tell is
/// stale is worse than no total.
class ReportErrorView extends StatelessWidget {
  const ReportErrorView({
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
                'This report could not be read',
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

/// The state between opening the screen and the figures arriving.
///
/// ## Why there is no spinner
///
/// These reports are four aggregate queries against a local SQLite file. On a counter
/// terminal that is over before a spinner could complete one revolution, so an animation
/// would be a flicker rather than information.
///
/// It also keeps the screen quiescent while it waits, which matters beyond taste: a widget
/// that animates forever is a widget no test can wait for, and the shell's own navigation
/// test settles the tree after switching sections.
///
/// What is shown instead is a plain statement that the figures are being read, and — the
/// important part — no figures. A zero standing in for an unread total is a number somebody
/// writes down.
class ReportLoadingView extends StatelessWidget {
  const ReportLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Reading the sales for these dates…',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// An honest empty state: nothing was sold in these dates, and why that is all it means.
///
/// Deliberately shows no example figures. A greyed-out "₹12,480 · 34 bills" would be
/// indistinguishable from a real report at a glance, and somebody would eventually read a
/// number off it and write it down.
class ReportEmptyView extends StatelessWidget {
  const ReportEmptyView({
    required this.title,
    required this.message,
    this.icon = Icons.receipt_long_outlined,
    super.key,
  });

  final IconData icon;

  final String title;

  final String message;

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
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled figure, used across the reports.
///
/// A card rather than a chart. The outlet reads these standing at a till, and a number
/// with its name above it is faster to read than anything plotted.
class ReportFigureCard extends StatelessWidget {
  const ReportFigureCard({
    required this.label,
    required this.value,
    this.caption,
    super.key,
  });

  final String label;

  final String value;

  /// A short qualifier under the figure, for example what it excludes.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(value, style: theme.textTheme.headlineSmall),
            if (caption != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                caption!,
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
}
