import 'package:flutter/material.dart';

/// Honest stand-in for a module that has not been built yet.
///
/// It states plainly that the module is pending and lists what it will own. This
/// is deliberate: a placeholder that showed mock totals or sample orders would be
/// indistinguishable from a working screen, and would hide real progress.
///
/// Every use of this widget is a tracked piece of remaining work. When a module
/// ships, its screen stops using this widget.
class ModulePlaceholder extends StatelessWidget {
  const ModulePlaceholder({
    required this.title,
    required this.icon,
    required this.scope,
    super.key,
  });

  /// Module name, matching the navigation label.
  final String title;

  final IconData icon;

  /// Responsibilities this module will take on once implemented.
  final List<String> scope;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, size: 28, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: theme.textTheme.headlineSmall),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Not implemented yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Planned responsibilities',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final String item in scope)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 10),
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: Text(item, style: theme.textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
