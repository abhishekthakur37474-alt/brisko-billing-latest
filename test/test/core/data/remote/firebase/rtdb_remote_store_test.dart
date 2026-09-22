import 'dart:convert';

import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/remote/firebase/rtdb_remote_store.dart';
import 'package:brisko_billing/core/data/remote/firebase/rtdb_rest_client.dart';
import 'package:brisko_billing/core/data/sync/sync_state.dart';
import 'package:brisko_billing/core/data/sync/syncable_entity.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../helpers/recording_http_server.dart';

class _FakeEntity implements SyncableEntity {
  const _FakeEntity({required this.id, required this.updatedAt, this.label});

  factory _FakeEntity.fromRow(Map<String, Object?> row) => _FakeEntity(
    id: row['id']! as String,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      row['updatedAt']! as int,
      isUtc: true,
    ),
    label: row['label'] as String?,
  );

  @override
  final String id;
  @override
  final DateTime updatedAt;
  final String? label;

  @override
  bool get isDeleted => false;
  @override
  SyncState get syncState => SyncState.pending;

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'isDeleted': 0,
    'syncState': syncState.name,
    'label': label,
  };
}

void main() {
  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-billing',
    apiKey: 'web-api-key',
    refreshToken: 'stored-refresh',
  );

  late RecordingHttpServer server;

  RtdbRemoteStore<_FakeEntity> storeFor(
    RecordingHttpServer server,
    String collection,
  ) {
    final FirebaseAuthClient authClient = FirebaseAuthClient(
      config: config,
      secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
    );
    final RtdbRestClient client = RtdbRestClient(
      config: config,
      session: FirebaseAuthSession(config: config, authClient: authClient),
      baseUrl: server.baseUrl,
    );
    return RtdbRemoteStore<_FakeEntity>(
      client: client,
      collection: collection,
      fromRow: _FakeEntity.fromRow,
    );
  }

  setUp(() async {
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  test(
    'push sends the entity map and pull rebuilds entities via fromRow',
    () async {
      server.responder = (RecordedRequest request) async {
        if (request.path.contains('/securetoken/')) {
          return HttpResponseSpec(
            200,
            jsonEncode(<String, dynamic>{
              'id_token': 'id-token',
              'refresh_token': 'r',
              'user_id': 'restaurant-abc',
              'expires_in': '3600',
            }),
          );
        }
        if (request.method == 'GET') {
          return HttpResponseSpec(
            200,
            jsonEncode(<String, dynamic>{
              'cus_1': <String, dynamic>{
                'id': 'cus_1',
                'updatedAt': 1750000000000,
                'label': 'Aisha',
              },
            }),
          );
        }
        return const HttpResponseSpec(200, 'null');
      };

      final RtdbRemoteStore<_FakeEntity> store = storeFor(
        server,
        'customers',
      );

      final Result<void> pushed = await store.push(
        _FakeEntity(
          id: 'cus_1',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            1750000000000,
            isUtc: true,
          ),
          label: 'Aisha',
        ),
      );
      expect(pushed.isOk, isTrue);

      final Result<List<_FakeEntity>> pulled = await store.pullChangedSince(
        null,
      );
      final List<_FakeEntity> entities = pulled.valueOrNull!;
      expect(entities, hasLength(1));
      expect(entities.first.id, 'cus_1');
      expect(entities.first.label, 'Aisha');
    },
  );
}
