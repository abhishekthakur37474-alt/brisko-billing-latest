// ignore_for_file: avoid_print
import 'dart:io';

import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/core/data/connectivity/network_probe.dart';
import 'package:brisko_billing/core/data/local/sqlite/database_factory_initializer.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_options.dart';
import 'package:brisko_billing/core/data/sync/sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_status_snapshot.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/auth/presentation/controllers/auth_controller.dart';
import 'package:brisko_billing/features/cloud_sync/presentation/controllers/sync_status_controller.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runtime cloud sync verification against real backend and database', () async {
    initializeDatabaseFactory();

    final String dbPath =
        '${Directory.current.path}/.dart_tool/sqflite_common_ffi/databases/brisko_billing.db';
    expect(File(dbPath).existsSync(), isTrue, reason: 'Real local database must exist');

    final SqliteDatabase database = SqliteDatabase();
    await database.open(path: dbPath);

    final SqliteSettingsRepository settings = SqliteSettingsRepository(database: database);
    final Map<String, String?> stored = (await settings.readAll()).valueOrNull ?? {};

    // 1. Verify Firebase login works / session is authenticated
    final AuthSessionStore sessionStore = AuthSessionStore(settings: settings);
    final PersistedSession? persistedSession = sessionStore.fromStored(stored);
    expect(persistedSession, isNotNull, reason: '1. Firebase session must be persisted locally');
    expect(persistedSession!.refreshToken, isNotEmpty);
    expect(persistedSession.email, isNotEmpty);
    print('[VERIFIED 1] Firebase login works: authenticated as ${persistedSession.email}');

    // 2. Verify Cloud backend is Configured
    const String projectId = 'brisko-billing';
    const String apiKey = 'AIzaSyDk8DOD4n2P7Bzrj3Cay_DwBKV2s-xOOew';
    final FirebaseConfig cloudConfig = FirebaseConfig(
      projectId: projectId,
      apiKey: apiKey,
      refreshToken: persistedSession.refreshToken,
    );
    expect(cloudConfig.isConfigured, isTrue);
    print('[VERIFIED 2] Cloud backend is Configured: projectId=$projectId');

    // 3. Verify Cloud connection is Online
    final HostLookupProbe probe = HostLookupProbe(host: FirebaseConfig.rtdbHost);
    final bool canReachRtdb = await probe.isReachable();
    expect(canReachRtdb, isTrue, reason: '3. Host ${FirebaseConfig.rtdbHost} must be reachable');
    print('[VERIFIED 3] Cloud connection is Online: reachable=${FirebaseConfig.rtdbHost}');
    await database.close();

    final dependencies = await bootstrap(
      databasePath: dbPath,
      firebaseOptions: const FirebaseOptions(
        projectId: projectId,
        apiKey: apiKey,
      ),
    );

    try {
      final SyncCoordinator coordinator = dependencies.syncCoordinator;
      final AuthController authController = dependencies.authController;

      expect(authController.isAuthenticated, isTrue);
      expect(dependencies.isCloudConfigured, isTrue);

      final SyncStatusController statusController = SyncStatusController(
        coordinator: coordinator,
        isCloudConfigured: dependencies.isCloudConfigured,
      );

      // 4. Run syncNow and verify it succeeds
      print('Triggering syncNow()...');
      final Result<void> syncResult = await coordinator.syncNow();
      expect(syncResult.isOk, isTrue, reason: '4. Cloud sync must succeed without errors');
      print('[VERIFIED 4] Sync succeeds: result is Ok');
      await Future<void>.delayed(Duration.zero);

      // 5. Verify sync status no longer shows an error
      final SyncStatusSnapshot snapshot = coordinator.currentStatus;
      expect(snapshot.lastError, isNull, reason: '5. Sync status must not have any error');
      expect(statusController.lastError, isNull);
      expect(statusController.state, SyncIndicatorState.synced);
      expect(statusController.detail, startsWith('Synced'));
      print('[VERIFIED 5] Sync status no longer shows an error: detail="${statusController.detail}"');

      // 6. Verify pending changes remains correct
      expect(snapshot.pendingCount, 0, reason: '6. Pending changes must be 0');
      expect(statusController.pendingCount, 0);
      print('[VERIFIED 6] Pending changes remains correct: 0 pending changes');

      statusController.dispose();
    } finally {
      await dependencies.dispose();
    }
  });
}
