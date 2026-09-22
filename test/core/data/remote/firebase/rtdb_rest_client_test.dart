import 'dart:convert';

import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/remote/firebase/rtdb_rest_client.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../helpers/recording_http_server.dart';

void main() {
  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-billing',
    apiKey: 'web-api-key',
    refreshToken: 'stored-refresh',
  );

  late RecordingHttpServer server;

  Future<HttpResponseSpec> Function(RecordedRequest) backend({
    required String uid,
    Object? collectionBody,
  }) {
    return (RecordedRequest request) async {
      if (request.path.contains('/securetoken/')) {
        return HttpResponseSpec(
          200,
          jsonEncode(<String, dynamic>{
            'id_token': 'id-token-for-$uid',
            'refresh_token': 'rotated',
            'user_id': uid,
            'expires_in': '3600',
          }),
        );
      }
      if (request.method == 'GET') {
        return HttpResponseSpec(200, jsonEncode(collectionBody ?? <String, dynamic>{}));
      }
      return const HttpResponseSpec(200, 'null');
    };
  }

  RtdbRestClient clientFor(RecordingHttpServer server) {
    final FirebaseAuthClient authClient = FirebaseAuthClient(
      config: config,
      secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
    );
    final FirebaseAuthSession session = FirebaseAuthSession(
      config: config,
      authClient: authClient,
    );
    return RtdbRestClient(
      config: config,
      session: session,
      baseUrl: server.baseUrl,
    );
  }

  setUp(() async {
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  test('an upsert patches nodes scoped to the signed-in restaurant', () async {
    server.responder = backend(uid: 'restaurant-abc');
    final RtdbRestClient client = clientFor(server);

    final Result<void> result = await client.upsert(
      'orders',
      <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ord_1',
          'updatedAt': 1750000000000,
          'totalAmountPaise': 45000,
          'orderNumber': '20260601-0001',
          'customerId': null,
        },
      ],
    );

    expect(result.isOk, isTrue);

    final RecordedRequest patch = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PATCH',
    );
    expect(patch.query['auth'], 'id-token-for-restaurant-abc');
    expect(
      patch.path,
      '/restaurants/restaurant-abc/orders.json',
    );

    final Map<String, dynamic> body = patch.json! as Map<String, dynamic>;
    expect(body['ord_1']['totalAmountPaise'], 45000);
    expect(body['ord_1']['orderNumber'], '20260601-0001');
    expect(body['ord_1'].containsKey('customerId'), isFalse);
  });

  test('the same id upserts in place, so a replay cannot duplicate', () async {
    server.responder = backend(uid: 'restaurant-abc');
    final RtdbRestClient client = clientFor(server);

    final Map<String, dynamic> row = <String, dynamic>{
      'id': 'ord_1',
      'updatedAt': 1750000000000,
    };
    await client.upsert('orders', <Map<String, dynamic>>[row]);
    await client.upsert('orders', <Map<String, dynamic>>[row]);

    final List<RecordedRequest> patches = server.requests
        .where((RecordedRequest r) => r.method == 'PATCH')
        .toList();
    for (final RecordedRequest patch in patches) {
      expect(patch.path, '/restaurants/restaurant-abc/orders.json');
      expect((patch.json! as Map<String, dynamic>).containsKey('ord_1'), isTrue);
    }
  });

  test('a different signed-in restaurant is scoped to a different path', () async {
    server.responder = backend(uid: 'restaurant-other');
    final RtdbRestClient client = clientFor(server);

    await client.upsert('orders', <Map<String, dynamic>>[
      <String, dynamic>{'id': 'ord_9', 'updatedAt': 1},
    ]);

    final RecordedRequest patch = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PATCH',
    );
    expect(patch.path, contains('/restaurants/restaurant-other/'));
    expect(patch.path, isNot(contains('restaurant-abc')));
  });

  test('selectChangedSince reads the node and filters by updatedAt', () async {
    server.responder = backend(
      uid: 'restaurant-abc',
      collectionBody: <String, dynamic>{
        'ord_old': <String, dynamic>{
          'id': 'ord_old',
          'updatedAt': 1750000000000,
          'totalAmountPaise': 1000,
        },
        'ord_1': <String, dynamic>{
          'id': 'ord_1',
          'updatedAt': 1750000005000,
          'totalAmountPaise': 45000,
        },
      },
    );
    final RtdbRestClient client = clientFor(server);

    final Result<List<Map<String, Object?>>> result = await client
        .selectChangedSince('orders', 1750000000000);

    final List<Map<String, Object?>> rows = result.valueOrNull!;
    expect(rows, hasLength(1));
    expect(rows.first['id'], 'ord_1');
    expect(rows.first['updatedAt'], 1750000005000);
    expect(rows.first['totalAmountPaise'], isA<int>());

    final RecordedRequest query = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'GET' && r.path.contains('/orders.json'),
    );
    expect(query.path, '/restaurants/restaurant-abc/orders.json');
  });

  test('a full pull (null cursor) returns every node', () async {
    server.responder = backend(
      uid: 'restaurant-abc',
      collectionBody: <String, dynamic>{
        'cus_1': <String, dynamic>{
          'id': 'cus_1',
          'updatedAt': 1,
        },
      },
    );
    final RtdbRestClient client = clientFor(server);

    final Result<List<Map<String, Object?>>> result =
        await client.selectChangedSince('customers', null);

    expect(result.valueOrNull, hasLength(1));
  });

  test('a soft delete patches only the deleted flag on the record node', () async {
    server.responder = backend(uid: 'restaurant-abc');
    final RtdbRestClient client = clientFor(server);

    await client.markDeleted('orders', 'ord_1');

    final RecordedRequest patch = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PATCH',
    );
    expect(patch.path, '/restaurants/restaurant-abc/orders/ord_1.json');
    final Map<String, dynamic> body = patch.json! as Map<String, dynamic>;
    expect(body['isDeleted'], 1);
    expect(body['syncState'], 'synced');
    expect(body.containsKey('updatedAt'), isTrue);
  });

  test('when sign-in is refused, nothing is uploaded and it surfaces', () async {
    server.responder = (RecordedRequest request) async {
      if (request.path.contains('/securetoken/')) {
        return HttpResponseSpec(400, '{"error":{"message":"INVALID"}}');
      }
      return const HttpResponseSpec(200, '{}');
    };
    final RtdbRestClient client = clientFor(server);

    final Result<void> result = await client.upsert(
      'orders',
      <Map<String, dynamic>>[
        <String, dynamic>{'id': 'ord_1', 'updatedAt': 1},
      ],
    );

    expect(result.isErr, isTrue);
    expect(result.failureOrNull, isA<RemoteFailure>());
    expect(
      server.requests.any((RecordedRequest r) => r.method == 'PATCH'),
      isFalse,
    );
  });

  test('a server refusal on patch is a RemoteFailure', () async {
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
      return const HttpResponseSpec(403, '{"error":"PERMISSION_DENIED"}');
    };
    final RtdbRestClient client = clientFor(server);

    final Result<void> result = await client.upsert(
      'orders',
      <Map<String, dynamic>>[
        <String, dynamic>{'id': 'ord_1', 'updatedAt': 1},
      ],
    );

    expect(result.failureOrNull, isA<RemoteFailure>());
  });

  test(
    'an unreachable RTDB host is a NetworkFailure, leaving work queued',
    () async {
      server.responder = backend(uid: 'restaurant-abc');

      final FirebaseAuthClient authClient = FirebaseAuthClient(
        config: config,
        secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
      );
      final FirebaseAuthSession session = FirebaseAuthSession(
        config: config,
        authClient: authClient,
      );
      final RecordingHttpServer dead = await RecordingHttpServer.start();
      final String deadBase = dead.baseUrl;
      await dead.close();

      final RtdbRestClient client = RtdbRestClient(
        config: config,
        session: session,
        baseUrl: deadBase,
      );

      final Result<void> result = await client.upsert(
        'orders',
        <Map<String, dynamic>>[
          <String, dynamic>{'id': 'ord_1', 'updatedAt': 1},
        ],
      );

      expect(result.failureOrNull, isA<NetworkFailure>());
    },
  );

  test('getRestaurantNode reads a singleton under the restaurant', () async {
    server.responder = backend(
      uid: 'restaurant-abc',
      collectionBody: <String, dynamic>{
        'hash': 'salt:abc',
        'updatedAt': 1750000000000,
      },
    );
    final RtdbRestClient client = clientFor(server);

    final Result<Map<String, Object?>> result = await client.getRestaurantNode(
      'managerPassword',
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull!['hash'], 'salt:abc');
    expect(result.valueOrNull!['updatedAt'], 1750000000000);

    final RecordedRequest get = server.requests.firstWhere(
      (RecordedRequest r) =>
          r.method == 'GET' && r.path.contains('/managerPassword.json'),
    );
    expect(get.path, '/restaurants/restaurant-abc/managerPassword.json');
  });

  test('putRestaurantNode overwrites the singleton node', () async {
    server.responder = backend(uid: 'restaurant-abc');
    final RtdbRestClient client = clientFor(server);

    final Result<void> result = await client.putRestaurantNode(
      'managerPassword',
      <String, dynamic>{'hash': 'salt:xyz', 'updatedAt': 2},
    );

    expect(result.isOk, isTrue);
    final RecordedRequest put = server.requests.firstWhere(
      (RecordedRequest r) => r.method == 'PUT',
    );
    expect(put.path, '/restaurants/restaurant-abc/managerPassword.json');
    final Map<String, dynamic> body = put.json! as Map<String, dynamic>;
    expect(body['hash'], 'salt:xyz');
    expect(body['updatedAt'], 2);
  });
}
