import 'dart:convert';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/remote/firebase/rtdb_rest_client.dart';
import 'package:brisko_billing/features/auth/domain/services/manager_auth_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/recording_http_server.dart';
import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-billing',
    apiKey: 'web-api-key',
    refreshToken: 'stored-refresh',
  );

  late SqliteDatabase database;
  late SqliteSettingsRepository settings;
  late RecordingHttpServer server;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    settings = SqliteSettingsRepository(database: database);
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await database.close();
    await server.close();
  });

  ManagerAuthService authFor({Object? nodeBody}) {
    server.responder = (RecordedRequest request) async {
      if (request.path.contains('/securetoken/')) {
        return HttpResponseSpec(
          200,
          jsonEncode(<String, dynamic>{
            'id_token': 'id-token',
            'refresh_token': 'rotated',
            'user_id': 'restaurant-abc',
            'expires_in': '3600',
          }),
        );
      }
      if (request.method == 'GET') {
        return HttpResponseSpec(200, jsonEncode(nodeBody ?? <String, dynamic>{}));
      }
      return const HttpResponseSpec(200, 'null');
    };

    final FirebaseAuthClient authClient = FirebaseAuthClient(
      config: config,
      secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
    );
    final FirebaseAuthSession session = FirebaseAuthSession(
      config: config,
      authClient: authClient,
    );
    return ManagerAuthService(
      settings: settings,
      rtdb: RtdbRestClient(
        config: config,
        session: session,
        baseUrl: server.baseUrl,
      ),
    );
  }

  test('setting a password PUTs the hash to RTDB, not Firestore', () async {
    final ManagerAuthService auth = authFor();

    expect((await auth.setPassword('1234')).isOk, isTrue);
    expect((await auth.verifyPassword('1234')).valueOrNull, isTrue);

    final RecordedRequest put = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PUT',
    );
    expect(put.path, '/restaurants/restaurant-abc/managerPassword.json');
    final Map<String, dynamic> body = put.json! as Map<String, dynamic>;
    expect(body['hash'], isA<String>());
    expect(body['hash'], contains(':'));
    expect(body['updatedAt'], isA<int>());
    expect(
      server.requests.any(
        (RecordedRequest r) => r.path.contains('firestore.googleapis.com'),
      ),
      isFalse,
    );
  });

  test('a newer RTDB hash overwrites the local cache', () async {
    await settings.writeAll(<String, String?>{
      SettingKeys.managerPassword: 'oldsalt:oldhash',
      SettingKeys.managerPasswordUpdatedAt: '1',
    });

    final ManagerAuthService auth = authFor(
      nodeBody: <String, dynamic>{
        'hash': 'newsalt:newhash',
        'updatedAt': 99,
      },
    );

    await auth.syncFromRtdb();

    expect(
      (await settings.readString(SettingKeys.managerPassword)).valueOrNull,
      'newsalt:newhash',
    );
    expect(
      (await settings.readInt(SettingKeys.managerPasswordUpdatedAt)).valueOrNull,
      99,
    );
  });

  test('a newer local hash is uploaded to RTDB', () async {
    await settings.writeAll(<String, String?>{
      SettingKeys.managerPassword: 'localsalt:localhash',
      SettingKeys.managerPasswordUpdatedAt: '50',
    });

    final ManagerAuthService auth = authFor(
      nodeBody: <String, dynamic>{
        'hash': 'remotesalt:remotehash',
        'updatedAt': 10,
      },
    );

    await auth.syncFromRtdb();

    final RecordedRequest put = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PUT',
    );
    expect(put.path, '/restaurants/restaurant-abc/managerPassword.json');
    final Map<String, dynamic> body = put.json! as Map<String, dynamic>;
    expect(body['hash'], 'localsalt:localhash');
    expect(body['updatedAt'], 50);
  });
}
