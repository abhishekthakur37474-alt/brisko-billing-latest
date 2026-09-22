import 'package:flutter/material.dart';

/// The state between opening Settings and the stored configuration arriving.
///
/// No spinner, and no empty form behind it. Reading a handful of rows from a local
/// SQLite file is over before an animation could complete a revolution, and a form
/// pre-filled with blanks would be indistinguishable from an unconfigured outlet — which
/// somebody would then save over the top of a real GSTIN.
///
/// A quiescent widget rather than an animated one, so a widget test can settle the tree.
class SettingsLoadingView extends StatelessWidget {
  const SettingsLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Reading this terminal’s settings…',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A storage failure that stopped the settings being read, with a way to try again.
///
/// Shown instead of the form, not beside it. An editable field next to a read error
/// would invite the operator to type over configuration that is on disk and merely
/// unreadable at this moment, and saving that would replace a real address with a blank
/// one.
class SettingsErrorView extends StatelessWidget {
  const SettingsErrorView({
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
                'These settings could not be read',
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

/// A failure that left the form as it was, with the edits still in it.
///
/// Sits above the fields rather than replacing them, because the operator's typing is
/// still there and pressing Save again is the whole remedy.
class SettingsSaveFailureBanner extends StatelessWidget {
  const SettingsSaveFailureBanner({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;

  /// Tries the same save again. Null while one is already in flight.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Not saved',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// One titled block of the settings form.
///
/// The screen is read standing at a counter, usually to change one thing. Grouping the
/// fields under a heading and a sentence saying what the group affects is what makes
/// that possible without a manual.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.title,
    required this.description,
    required this.children,
    super.key,
  });

  final String title;

  /// One line on what these fields change. Plain fact, no marketing.
  final String description;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A labelled row inside a section, for a choice rather than a text field.
///
/// Laid out as a label above its control rather than beside it, so a long label and a
/// wide control never fight over the same line on a counter display.
class SettingsChoiceField extends StatelessWidget {
  const SettingsChoiceField({
    required this.label,
    required this.child,
    this.helper,
    this.error,
    super.key,
  });

  final String label;

  /// What the choice means, in one line.
  final String? helper;

  /// Why the choice is refused, if it is.
  final String? error;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: theme.textTheme.labelLarge),
          if (helper != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              helper!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          child,
          if (error != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
