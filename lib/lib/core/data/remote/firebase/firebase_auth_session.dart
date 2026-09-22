import 'dart:async';

import '../../../error/app_failure.dart';
import '../../../utils/result.dart';
import 'firebase_auth_client.dart';
import 'firebase_config.dart';

/// The signed-in context an RTDB request needs: which restaurant it may touch,
/// and the bearer token proving it.
class FirebaseAuthContext {
  const FirebaseAuthContext({
    required this.restaurantId,
    required this.idToken,
  });

  /// The restaurant scope in `restaurants/{restaurantId}/…`. Equal to the signed-in
  /// user's `uid`, which is what the security rules match on, so a terminal can only
  /// ever address its own restaurant's documents.
  final String restaurantId;

  /// The current, unexpired ID token for the `Authorization` header.
  final String idToken;
}

/// Holds a terminal's Firebase session and keeps a valid ID token to hand.
///
/// The terminal is configured with a long-lived refresh token, not a password. This
/// session exchanges it for a short-lived ID token, caches that token with its expiry,
/// and refreshes it just before it lapses — so the RTDB client can ask for a valid
/// credential on every call without knowing anything about token lifetimes.
///
/// It is deliberately conservative about failure. A refresh that cannot reach the
/// server is a [NetworkFailure], which the sync engine already treats as "offline,
/// leave it queued". A refresh the server refuses is a [RemoteFailure], surfaced so the
/// operator can fix the account, and retried on the next cycle rather than in a loop.
class FirebaseAuthSession {
  FirebaseAuthSession({
    required this.config,
    required this._authClient,
    this.refreshMargin = const Duration(minutes: 1),
  });

  final FirebaseConfig config;
  final FirebaseAuthClient _authClient;

  /// How long before expiry a token is considered due for refresh, so a request never
  /// races the clock and arrives with a just-expired token.
  final Duration refreshMargin;

  FirebaseAuthTokens? _tokens;

  /// The refresh token in use, seeded from configuration and updated whenever Firebase
  /// rotates it during a refresh.
  String? _refreshToken;

  /// True once [clear] has been called, so a signed-out terminal does not silently fall
  /// back to the refresh token still held in [config]. Reset by [adopt] on a fresh
  /// sign-in.
  bool _signedOut = false;

  /// Serialises concurrent refreshes: several stores may ask for a token at once when a
  /// cycle begins, and they should share one network round-trip rather than each firing
  /// its own.
  Future<Result<FirebaseAuthContext>>? _inFlight;

  /// Returns a valid signed-in context, refreshing the ID token if needed.
  Future<Result<FirebaseAuthContext>> current() {
    final FirebaseAuthTokens? tokens = _tokens;
    if (tokens != null && !_isExpiring(tokens)) {
      return Future<Result<FirebaseAuthContext>>.value(
        Ok<FirebaseAuthContext>(
          FirebaseAuthContext(
            restaurantId: tokens.uid,
            idToken: tokens.idToken,
          ),
        ),
      );
    }
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  /// Adopts a session obtained elsewhere, for example from the sign-in screen.
  ///
  /// This is how a login hands its result to the running application: the tokens replace
  /// whatever was held, and the terminal counts as signed in again even if it had been
  /// signed out earlier in the same run.
  void adopt(FirebaseAuthTokens tokens) {
    _tokens = tokens;
    _refreshToken = tokens.refreshToken;
    _signedOut = false;
  }

  /// Forgets the session, so the terminal is treated as signed out.
  ///
  /// After this, [current] reports "not signed in" without a network call and without
  /// reusing the refresh token that may still sit in [config] — a logged-out terminal
  /// must not keep reaching the cloud. Signing in again through [adopt] restores it.
  ///
  /// This only drops the in-memory credential; it deletes nothing on disk and touches no
  /// local data. Removing the persisted session is the caller's concern.
  void clear() {
    _tokens = null;
    _refreshToken = null;
    _signedOut = true;
  }

  /// Whether the terminal currently holds a session it could sign a request with: an
  /// unexpired or refreshable token, or a stored refresh token it has not been signed out
  /// of.
  bool get hasSession {
    if (_signedOut) {
      return false;
    }
    if (_tokens != null || (_refreshToken?.trim().isNotEmpty ?? false)) {
      return true;
    }
    return config.refreshToken?.trim().isNotEmpty ?? false;
  }

  Future<Result<FirebaseAuthContext>> _refresh() async {
    // A signed-out terminal never falls back to config's refresh token; only an explicit
    // sign-in (adopt) puts it back in a state where it can refresh.
    final String? refreshToken = _signedOut
        ? _refreshToken
        : (_refreshToken ?? config.refreshToken?.trim());
    if (refreshToken == null || refreshToken.isEmpty) {
      return const Err<FirebaseAuthContext>(
        RemoteFailure(
          'This terminal is not signed in to the cloud. Add a Firebase session '
          'in Settings.',
        ),
      );
    }

    final Result<FirebaseAuthTokens> result = await _authClient.refresh(
      refreshToken,
    );
    return result.fold(
      onOk: (FirebaseAuthTokens tokens) {
        _tokens = tokens;
        _refreshToken = tokens.refreshToken;
        return Ok<FirebaseAuthContext>(
          FirebaseAuthContext(
            restaurantId: tokens.uid,
            idToken: tokens.idToken,
          ),
        );
      },
      onErr: Err<FirebaseAuthContext>.new,
    );
  }

  bool _isExpiring(FirebaseAuthTokens tokens) {
    final DateTime threshold = DateTime.now().toUtc().add(refreshMargin);
    return !tokens.expiresAt.isAfter(threshold);
  }
}
