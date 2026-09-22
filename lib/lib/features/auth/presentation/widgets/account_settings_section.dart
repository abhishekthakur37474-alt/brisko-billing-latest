import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../cloud_sync/presentation/controllers/sync_status_controller.dart';
import '../controllers/auth_controller.dart';

/// The Account section on the Settings screen.
///
/// Shows which account this terminal is signed in as, and offers the one action a signed-in
/// terminal needs: sign out. Cloud connection status and the manual "Sync now" live in the
/// Cloud & Backup section beside it; this is only about identity.
///
/// It renders nothing on a build with no cloud (there is no account to show) and nothing
/// when no [AuthController] has been provided, so a screen shown outside the full
/// application shell is never forced to wire one up.
class AccountSettingsSection extends StatelessWidget {
  const AccountSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController? auth = context.watch<AuthController?>();
    if (auth == null || !auth.isCloudEnabled || !auth.isAuthenticated) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Account', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'The cloud account this terminal is signed in to. Signing out '
              'stops syncing until you sign in again; nothing on this device is '
              'deleted.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),
            Row(
              children: <Widget>[
                Icon(
                  Icons.account_circle_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    auth.signedInEmail ?? 'Signed in',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _confirmSignOut(context, auth),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(
    BuildContext context,
    AuthController auth,
  ) async {
    // Read the pending count if the sync controller is available, so an operator with
    // unsynced work is warned before they sign out rather than after.
    final SyncStatusController? sync = context.read<SyncStatusController?>();
    final int pending = sync?.pendingCount ?? 0;

    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('Sign out?'),
              content: Text(
                pending > 0
                    ? 'There ${pending == 1 ? 'is' : 'are'} $pending '
                          '${pending == 1 ? 'change' : 'changes'} still waiting '
                          'to upload. They stay saved on this device and will '
                          'upload the next time you sign in. Sign out anyway?'
                    : 'Cloud syncing stops until you sign in again. Your sales '
                          'and settings stay on this device. Sign out?',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Sign out'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (confirmed) {
      await auth.signOut();
    }
  }
}
