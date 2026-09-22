import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../error/app_failure.dart';
import '../../../utils/result.dart';
import 'firebase_auth_session.dart';
import 'firebase_config.dart';
import 'rtdb_paths.dart';

/// A thin Firebase Realtime Database client over `dart:io`.
///
/// One place that knows the RTDB REST shape: how a row is written under
/// `restaurants/{restaurantId}/{node}/{id}`, how a "changed since" pull becomes a
/// collection GET plus an `updatedAt` filter, and how an HTTP outcome becomes an
/// [AppFailure]. Everything above it works in terms of rows and never sees a path.
///
/// Every call first asks the [FirebaseAuthSession] for a valid ID token and the
/// restaurant scope. A session that cannot be refreshed because the link is down
/// yields a [NetworkFailure], so the work stays queued; a session the server
/// refused yields a [RemoteFailure], surfaced and retried later. The restaurant
/// scope is the signed-in `uid`, so the client can only ever address the
/// terminal's own restaurant — the same boundary the security rules enforce.
class RtdbRestClient {
  RtdbRestClient({
    required this.config,
    required this.session,
    HttpClient? httpClient,
    String? baseUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _client = httpClient ?? HttpClient(),
       baseUrl = baseUrl ?? config.databaseUrl;

  final FirebaseConfig config;
  final FirebaseAuthSession session;

  /// Base of the RTDB REST endpoint, without a trailing slash. Overridable so
  /// tests can point the client at a local server instead of Google's.
  final String baseUrl;

  final HttpClient _client;
  final Duration timeout;

  String get _root {
    if (baseUrl.endsWith('/')) {
      return baseUrl.substring(0, baseUrl.length - 1);
    }
    return baseUrl;
  }

  /// Inserts or overwrites [rows] in [collection] for the signed-in restaurant.
  ///
  /// Each write is keyed by the row's stable `id`, so replaying a queued write
  /// or running a restore updates the node in place rather than creating a
  /// second copy. Rows are PATCHed onto the collection node in chunks.
  Future<Result<void>> upsert(
    String collection,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) {
      return const Ok<void>(null);
    }
    return _withAuth((FirebaseAuthContext auth) async {
      for (final List<Map<String, dynamic>> chunk in _chunk(rows, 100)) {
        final Map<String, dynamic> patch = <String, dynamic>{
          for (final Map<String, dynamic> row in chunk)
            row['id'] as String: _omitNulls(row),
        };
        final Result<void> result = await _send<void>(
          method: 'PATCH',
          uri: _uri(auth, RtdbPaths.collection(auth.restaurantId, collection)),
          body: jsonEncode(patch),
          onSuccess: (_) {},
          context: 'upload records',
        );
        if (result.isErr) {
          return result;
        }
      }
      return const Ok<void>(null);
    });
  }

  /// Marks a node soft-deleted in the cloud.
  ///
  /// The engine normally propagates a deletion by upserting the whole
  /// soft-deleted row; this patches only the flag when an id is all that is to
  /// hand, so no other field is disturbed.
  Future<Result<void>> markDeleted(String collection, String id) async {
    return _withAuth((FirebaseAuthContext auth) {
      return _send<void>(
        method: 'PATCH',
        uri: _uri(auth, RtdbPaths.record(auth.restaurantId, collection, id)),
        body: jsonEncode(<String, dynamic>{
          'isDeleted': 1,
          'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
          'syncState': 'synced',
        }),
        onSuccess: (_) {},
        context: 'upload a deletion',
      );
    });
  }

  /// Reads the whole restaurant node as a JSON object.
  ///
  /// Used to snapshot the cloud before a till wipe. An empty or missing node is
  /// an empty map, not a failure — a new restaurant has nothing to back up.
  Future<Result<Map<String, Object?>>> getRestaurant() {
    return _withAuth((FirebaseAuthContext auth) {
      return _send<Map<String, Object?>>(
        method: 'GET',
        uri: _uri(auth, RtdbPaths.restaurant(auth.restaurantId)),
        onSuccess: _decodeObject,
        context: 'download the restaurant backup',
      );
    });
  }

  /// Physically removes the restaurant node, every collection under it included.
  ///
  /// This is the cloud half of "Clear till data". Sync uses [markDeleted] for a
  /// single row; emptying the outlet is a different operation and lives here.
  Future<Result<void>> deleteRestaurant() {
    return _withAuth((FirebaseAuthContext auth) {
      return _send<void>(
        method: 'DELETE',
        uri: _uri(auth, RtdbPaths.restaurant(auth.restaurantId)),
        onSuccess: (_) {},
        context: 'clear the cloud restaurant',
      );
    });
  }

  /// Reads nodes from [collection] whose `updatedAt` is greater than
  /// [sinceMillis], oldest change first. A `null` [sinceMillis] reads
  /// everything, which is what a fresh terminal needs to restore.
  Future<Result<List<Map<String, Object?>>>> selectChangedSince(
    String collection,
    int? sinceMillis,
  ) async {
    return _withAuth((FirebaseAuthContext auth) {
      return _send<List<Map<String, Object?>>>(
        method: 'GET',
        uri: _uri(auth, RtdbPaths.collection(auth.restaurantId, collection)),
        onSuccess: (String body) => _decodeCollection(body, sinceMillis),
        context: 'download records',
      );
    });
  }

  Future<void> close() async => _client.close(force: true);

  Future<Result<T>> _withAuth<T>(
    Future<Result<T>> Function(FirebaseAuthContext auth) action,
  ) async {
    final Result<FirebaseAuthContext> auth = await session.current();
    return switch (auth) {
      Ok<FirebaseAuthContext>(:final FirebaseAuthContext value) => action(
        value,
      ),
      Err<FirebaseAuthContext>(:final AppFailure failure) => Err<T>(failure),
    };
  }

  Uri _uri(FirebaseAuthContext auth, String path) {
    return Uri.parse('$_root/$path.json').replace(
      queryParameters: <String, String>{'auth': auth.idToken},
    );
  }

  static Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (int i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }

  /// Decodes a GET of a node that may be missing (`null`) into a map.
  static Map<String, Object?> _decodeObject(String body) {
    if (body.isEmpty || body == 'null') {
      return const <String, Object?>{};
    }
    final Object? decoded = jsonDecode(body);
    if (decoded == null) {
      return const <String, Object?>{};
    }
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object');
    }
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
        entry.key.toString(): entry.value,
    };
  }

  /// RTDB drops keys whose value is JSON null, so they are omitted on write.
  static Map<String, dynamic> _omitNulls(Map<String, dynamic> row) {
    return <String, dynamic>{
      for (final MapEntry<String, dynamic> entry in row.entries)
        if (entry.value != null) entry.key: entry.value,
    };
  }

  static List<Map<String, Object?>> _decodeCollection(
    String body,
    int? sinceMillis,
  ) {
    if (body.isEmpty || body == 'null') {
      return const <Map<String, Object?>>[];
    }
    final Object? decoded = jsonDecode(body);
    if (decoded == null) {
      return const <Map<String, Object?>>[];
    }
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object of RTDB records');
    }

    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final MapEntry<dynamic, dynamic> entry in decoded.entries) {
      final Object? value = entry.value;
      if (value is! Map) {
        continue;
      }
      final Map<String, Object?> row = _normalizeRow(<String, Object?>{
        for (final MapEntry<dynamic, dynamic> field in value.entries)
          field.key.toString(): field.value,
      });
      row['id'] ??= entry.key.toString();
      if (sinceMillis != null) {
        final int? updatedAt = _asInt(row['updatedAt']);
        if (updatedAt == null || updatedAt <= sinceMillis) {
          continue;
        }
      }
      rows.add(row);
    }
    rows.sort((Map<String, Object?> a, Map<String, Object?> b) {
      return (_asInt(a['updatedAt']) ?? 0).compareTo(
        _asInt(b['updatedAt']) ?? 0,
      );
    });
    return rows;
  }

  /// SQLite `fromRow` expects ints, not JSON numbers-as-doubles.
  static Map<String, Object?> _normalizeRow(Map<String, Object?> row) {
    return <String, Object?>{
      for (final MapEntry<String, Object?> entry in row.entries)
        entry.key: _normalizeValue(entry.value),
    };
  }

  static Object? _normalizeValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value.toInt();
    }
    return value;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  Future<Result<T>> _send<T>({
    required String method,
    required Uri uri,
    required T Function(String body) onSuccess,
    required String context,
    String? body,
  }) async {
    try {
      final HttpClientRequest request = await _client
          .openUrl(method, uri)
          .timeout(timeout);

      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }

      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return Ok<T>(onSuccess(responseBody));
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        return Err<T>(
          RemoteFailure(
            'The cloud rejected the terminal\'s credentials. Check the Firebase '
            'sign-in and the security rules.',
            cause: responseBody,
          ),
        );
      }

      return Err<T>(
        RemoteFailure(
          'The cloud could not $context (HTTP ${response.statusCode}).',
          cause: responseBody,
        ),
      );
    } on SocketException catch (error) {
      return Err<T>(NetworkFailure('The cloud is unreachable.', cause: error));
    } on TimeoutException catch (error) {
      return Err<T>(
        NetworkFailure('The cloud did not respond in time.', cause: error),
      );
    } on HandshakeException catch (error) {
      return Err<T>(
        NetworkFailure(
          'The secure connection to the cloud failed.',
          cause: error,
        ),
      );
    } on FormatException catch (error) {
      return Err<T>(
        RemoteFailure(
          'The cloud returned data that could not be read.',
          cause: error,
        ),
      );
    } on Object catch (error) {
      return Err<T>(
        NetworkFailure('The cloud could not $context.', cause: error),
      );
    }
  }
}
