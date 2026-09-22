import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../controllers/sync_status_controller.dart';

/// The Cloud & Backup section on the Settings screen.
///
/// Shows the honest state of synchronisation and offers a manual "Sync now", and
/// nothing more. There is no schedule to configure and no backup button, because
/// the automatic sync is the backup: every change is uploaded as soon as the link
/// allows, and the last successful sync is the last point the outlet could be
/// restored to.
///
/// It never blocks billing. "Sync now" is a convenience for a cashier who wants to
/// be sure before closing the till, not a step normal operation depends on.
class CloudSyncSettingsSection extends StatelessWidget {
  const CloudSyncSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    // Nullable lookup on purpose: the section renders nothing if the app has not
    // provided a sync controller, so a screen shown outside the full app shell is
    // never forced to wire one up.
    final SyncStatusController? controller = context
        .watch<SyncStatusController?>();
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Cloud & Backup', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Your data is saved on this device first and synced to the cloud '
              'when online. The cloud copy is the backup used to restore a new '
              'or reinstalled terminal.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),

            _StatusRow(
              label: 'Cloud backend',
              value: controller.isCloudConfigured
                  ? 'Configured'
                  : 'Not configured',
            ),
            _StatusRow(
              label: 'Cloud connection',
              value: controller.isOnline ? 'Online' : 'Offline',
            ),
            _StatusRow(label: 'Sync status', value: controller.detail),
            _StatusRow(
              label: 'Pending changes',
              value: '${controller.pendingCount}',
            ),

            if (controller.state == SyncIndicatorState.failed && controller.lastDiagnostic != null) ...[
              const SizedBox(height: 16),
              _DiagnosticPanel(diagnosticJson: controller.lastDiagnostic!),
            ],

            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed:
                      controller.isCloudConfigured && !controller.isSyncing
                      ? () => _syncNow(context, controller)
                      : null,
                  icon: controller.isSyncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(controller.isSyncing ? 'Syncing…' : 'Sync now'),
                ),
                if (!controller.isCloudConfigured) ...<Widget>[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Add the cloud URL and key to enable syncing.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow(
    BuildContext context,
    SyncStatusController controller,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await controller.syncNow();
    if (!context.mounted) {
      return;
    }
    final String message = controller.isOnline
        ? (controller.lastError == null
              ? 'Sync complete.'
              : 'Sync did not finish: ${controller.lastError}')
        : 'You are offline. Changes will sync when the connection returns.';
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DiagnosticPanel extends StatelessWidget {
  const _DiagnosticPanel({required this.diagnosticJson});
  final String diagnosticJson;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Map<String, dynamic> diag = <String, dynamic>{};
    try {
      diag = jsonDecode(diagnosticJson) as Map<String, dynamic>;
    } catch (_) {}

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Text(
                'Sync Failed Diagnostics',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Reason: ${diag['error'] ?? 'Unknown'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          Text('Operation: ${diag['operation'] ?? 'Unknown'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          if (diag['collection'] != null) Text('Collection: ${diag['collection']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          if (diag['recordId'] != null) Text('Record ID: ${diag['recordId']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => _exportDiagnostics(context),
            icon: const Icon(Icons.download),
            label: const Text('Export sync diagnostics'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onErrorContainer.withValues(alpha: 0.1),
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportDiagnostics(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String dbPath = await getDatabasesPath();
      final File logFile = File(p.join(dbPath, 'sync_diagnostics.log'));
      
      if (!logFile.existsSync()) {
        messenger.showSnackBar(const SnackBar(content: Text('No diagnostic log found.')));
        return;
      }
      
      final String userProfile = Platform.environment['USERPROFILE'] ?? '';
      if (userProfile.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Could not locate user profile directory.')));
        return;
      }
      
      final File destFile = File(p.join(userProfile, 'Desktop', 'brisko_sync_diagnostics.txt'));
      await logFile.copy(destFile.path);
      
      messenger.showSnackBar(SnackBar(content: Text('Exported to: ${destFile.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to export: $e')));
    }
  }
}
