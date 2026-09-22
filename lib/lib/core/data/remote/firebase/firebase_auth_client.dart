import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../error/app_failure.dart';
import '../../../utils/result.dart';
import 'firebase_config.dart';

/// The identity a signed-in terminal carries: a short-lived ID token and the `uid`
/// that names the restaurant it may read and write.
class FirebaseAuthTokens {
  const FirebaseAuthTokens({
    required this.idToken,
    required this.refreshToken,
    required this.uid,
    required this.expiresAt,
  });

  /// The bearer credential for Realtime Database requests. Expires within the hour.
  final String idToken;

  /// The long-lived session, exchanged for a new [idToken] when this one nears
  /// expiry. Firebase may rotate it, so the latest value is always kept.
  final String refreshToken;

  /// The signed-in user's id, which is also the restaurant scope in the document
  /// path `restaurants/{uid}/…` and the value the security rules match on.
  final String uid;

  /// When [idToken] stops being valid, in UTC.
  final DateTime expiresAt;
}

/// A thin client over Firebase Authentication's REST APIs.
///
/// Two endpoints only: exchanging an email and password for a session
/// (Identity Toolkit `accounts:signInWithPassword`), and refreshing a session into a
/// fresh ID token (Secure Token `token`). Both are what a native SDK calls under the
/// hood; using them directly keeps the terminal free of native plugins.
///
/// The failure mapping mirrors the rest of the sync layer: a connection that could not
/// be made is a [NetworkFailure] — the ordinary offline condition that leaves work
/// queued — while a request the server refused (bad credentials, disabled account) is a
/// [RemoteFailure], surfaced but never a reason to lose local data.
class FirebaseAuthClient {
  FirebaseAuthClient({
    required this.config,
    HttpClient? httpClient,
    this.identityBaseUrl = 'https://identitytoolkit.googleapis.com/v1',
    this.secureTokenBaseUrl = 'https://securetoken.googleapis.com/v1',
    this.timeout = const Duration(seconds: 20),
  }) : _client = httpClient ?? HttpClient();

  final FirebaseConfig config;
  final HttpClient _client;

  /// Base of the Identity Toolkit endpoint. Overridable so tests can point the client
  /// at a local server instead of Google's.
  final String identityBaseUrl;

  /// Base of the Secure Token endpoint. Overridable for the same reason.
  final String secureTokenBaseUrl;

  final Duration timeout;

  /// Signs in with an email and password, returning the session.
  ///
  /// Kept for completeness and for a future sign-in screen; the terminal normally runs
  /// from a stored refresh token and never handles the password again.
  Future<Result<FirebaseAuthTokens>> signInWithPassword(
    String email,
    String password,
  ) async {
    final Uri uri = Uri.parse(
      '$identityBaseUrl/accounts:signInWithPassword?key=${config.apiKey}',
    );
    return _send(
      uri: uri,
      body: jsonEncode(<String, dynamic>{
        'email': email,
        'password': password,
        'returnSecureToken': true,
      }),
      context: 'sign in',
      parse: (Map<String, dynamic> json) => FirebaseAuthTokens(
        idToken: json['idToken'] as String,
        refreshToken: json['refreshToken'] as String,
        uid: json['localId'] as String,
        expiresAt: _expiryFrom(json['expiresIn']),
      ),
    );
  }

  /// Exchanges a refresh token for a fresh ID token.
  Future<Result<FirebaseAuthTokens>> refresh(String refreshToken) async {
    final Uri uri = Uri.parse('$secureTokenBaseUrl/token?key=${config.apiKey}');
    return _send(
      uri: uri,
      body: jsonEncode(<String, dynamic>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      }),
      context: 'refresh the session',
      parse: (Map<String, dynamic> json) => FirebaseAuthTokens(
        idToken: json['id_token'] as String,
        refreshToken: json['refresh_token'] as String,
        uid: json['user_id'] as String,
        expiresAt: _expiryFrom(json['expires_in']),
      ),
    );
  }

  Future<void> close() async => _client.close(force: true);

  static DateTime _expiryFrom(Object? expiresIn) {
    final int seconds = int.tryParse(expiresIn?.toString() ?? '') ?? 3600;
    return DateTime.now().toUtc().add(Duration(seconds: seconds));
  }

  Future<Result<FirebaseAuthTokens>> _send({
    required Uri uri,
    required String body,
    required String context,
    required FirebaseAuthTokens Function(Map<String, dynamic> json) parse,
  }) async {
    try {
      final HttpClientRequest request = await _client
          .postUrl(uri)
          .timeout(timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'application/json');
      request.write(body);

      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Object? decoded = jsonDecode(responseBody);
        if (decoded is! Map<String, dynamic>) {
          return const Err<FirebaseAuthTokens>(
            RemoteFailure('The sign-in response could not be read.'),
          );
        }
        return Ok<FirebaseAuthTokens>(parse(decoded));
      }

      // Any non-success from the identity service is a credential or account problem:
      // the terminal reached the server, so this is not an offline condition.
      return Err<FirebaseAuthTokens>(
        RemoteFailure(
          'The cloud rejected the terminal\'s sign-in. Check the Firebase key '
          'and the terminal account in Settings.',
          cause: responseBody,
        ),
      );
    } on SocketException catch (error) {
      return Err<FirebaseAuthTokens>(
        NetworkFailure('The cloud is unreachable.', cause: error),
      );
    } on TimeoutException catch (error) {
      return Err<FirebaseAuthTokens>(
        NetworkFailure('The cloud did not respond in time.', cause: error),
      );
    } on HandshakeException catch (error) {
      return Err<FirebaseAuthTokens>(
        NetworkFailure(
          'The secure connection to the cloud failed.',
          cause: error,
        ),
      );
    } on FormatException catch (error) {
      return Err<FirebaseAuthTokens>(
        RemoteFailure('Could not $context.', cause: error),
      );
    } on Object catch (error) {
      return Err<FirebaseAuthTokens>(
        NetworkFailure('Could not $context.', cause: error),
      );
    }
  }
}
