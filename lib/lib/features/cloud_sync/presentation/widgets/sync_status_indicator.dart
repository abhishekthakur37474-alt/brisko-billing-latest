import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/sync_status_controller.dart';

/// The small, unobtrusive sync status shown in the POS shell's app bar.
///
/// It reports and never blocks. Whatever it says — synced, syncing, offline with a
/// count of pending changes, or failed — billing carries on underneath it. It is a
/// glance, not a control: the manual sync and the detail live in Settings, so the
/// header stays quiet during a shift.
class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final SyncStatusController? controller = context
        .watch<SyncStatusController?>();
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    final _IndicatorVisual visual = _visualFor(
      controller.state,
      theme.colorScheme,
    );

    return Tooltip(
      message: controller.detail,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            visual.isSpinning
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(visual.color),
                    ),
                  )
                : Icon(visual.icon, size: 16, color: visual.color),
            const SizedBox(width: 6),
            Text(
              controller.label,
              style: theme.textTheme.labelMedium?.copyWith(color: visual.color),
            ),
          ],
        ),
      ),
    );
  }

  static _IndicatorVisual _visualFor(
    SyncIndicatorState state,
    ColorScheme scheme,
  ) {
    return switch (state) {
      SyncIndicatorState.notConfigured => _IndicatorVisual(
        icon: Icons.cloud_off_outlined,
        color: scheme.onSurfaceVariant,
      ),
      SyncIndicatorState.offline => _IndicatorVisual(
        icon: Icons.cloud_off_outlined,
        color: scheme.onSurfaceVariant,
      ),
      SyncIndicatorState.syncing => _IndicatorVisual(
        icon: Icons.sync,
        color: scheme.primary,
        isSpinning: true,
      ),
      SyncIndicatorState.failed => _IndicatorVisual(
        icon: Icons.sync_problem,
        color: scheme.error,
      ),
      SyncIndicatorState.pendingChanges => _IndicatorVisual(
        icon: Icons.cloud_upload_outlined,
        color: scheme.primary,
      ),
      SyncIndicatorState.synced => _IndicatorVisual(
        icon: Icons.cloud_done_outlined,
        color: scheme.primary,
      ),
    };
  }
}

class _IndicatorVisual {
  const _IndicatorVisual({
    required this.icon,
    required this.color,
    this.isSpinning = false,
  });

  final IconData icon;
  final Color color;
  final bool isSpinning;
}
