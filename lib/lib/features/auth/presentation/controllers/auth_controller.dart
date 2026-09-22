import 'package:flutter/foundation.dart';

import '../../../../app/sync/cloud_sync_activation.dart';
import '../../../../core/data/remote/firebase/firebase_auth_client.dart';
import '../../../../core/data/remote/firebase/firebase_auth_session.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../data/auth_session_store.dart';

/// Where a sign-in attempt stands, so the login screen never has to reason about a bag of
/// booleans.
enum SignInStatus {
  /// Nothing in flight, and nothing failed since the last edit.
  idle,

  /// A sign-in request is running. The form must lock and show progress.
  submitting,

  /// The last attempt failed. [AuthController.errorMessage] says why, in words safe to
  /// put in front of a cashier.
  failed,
}

/// The terminal's sign-in state, and the one place sign-in and sign-out happen.
///
/// ## What it decides
///
/// Whether the application shows the login screen or the till. That is the whole of its
/// public purpose: [isAuthenticated] gates the app, and [signIn]/[signOut] move between
/// the two states. Everything else — the ID token, its refresh, the restaurant scope — is
/// the [FirebaseAuthSession]'s job, reused exactly as the sync engine already uses it, so
/// there is only ever one session in the terminal and never a second auth system.
///
/// ## What it does on the way in and out
///
/// Signing in exchanges an email and password for a session through the existing
/// [FirebaseAuthClient], persists that session so the next launch skips the login screen,
/// adopts it into the shared [FirebaseAuthSession] the sync transport signs its requests
/// with, and switches synchronisation on. Signing out clears the in-memory session, wipes
/// the persisted one, and switches synchronisation off — while leaving every local record
/// and every queued change exactly where it was.
///
/// ## What it never touches
///
/// The password, after the one exchange. It is passed to the auth client and then dropped;
/// it is written nowhere. No token, refresh token or credential is ever put into a message
/// this class exposes — [errorMessage] carries only the fixed, human sentences below.
///
/// ## The local-only build
///
/// When [isCloudEnabled] is false — a build compiled without a Firebase project — there is
/// no cloud to sign in to. The controller then reports itself permanently "authenticated"
/// in the sense the gate needs (the till opens straight away) and both [signIn] and
/// [signOut] are inert, so a purely local terminal behaves exactly as it did before any of
/// this existed.
class AuthController extends ChangeNotifier {
  AuthController({
    required this.isCloudEnabled,
    required bool initiallyAuthenticated,
    required AuthSessionStore sessionStore,
    String? initialEmail,
    FirebaseAuthClient? authClient,
    FirebaseAuthSession? session,
    CloudSyncActivation? syncActivation,
  }) : _sessionStore = sessionStore,
       _authClient = authClient,
       _session = session,
       _syncActivation = syncActivation,
       _isAuthenticated = isCloudEnabled ? initiallyAuthenticated : true,
       _email = initiallyAuthenticated ? initialEmail : null;

  // The collaborators above are assigned in the initializer list rather than as
  // initializing formals so the constructor can also derive the initial gate state from
  // them; see `_isAuthenticated`.
  // ignore_for_file: prefer_initializing_formals

  /// Whether this build talks to a Firebase project at all. False means a local-only
  /// build with no login step.
  final bool isCloudEnabled;

  final FirebaseAuthClient? _authClient;
  final FirebaseAuthSession? _session;
  final AuthSessionStore _sessionStore;
  final CloudSyncActivation? _syncActivation;

  bool _isAuthenticated;
  String? _email;
  SignInStatus _status = SignInStatus.idle;
  String? _errorMessage;
  bool _isDisposed = false;

  /// True when the till should be shown rather than the login screen.
  bool get isAuthenticated => _isAuthenticated;

  /// The signed-in account's email, for display in Settings. `null` when signed out.
  String? get signedInEmail => _email;

  SignInStatus get status => _status;

  /// True while a sign-in request is in flight.
  bool get isSubmitting => _status == SignInStatus.submitting;

  /// Why the last sign-in failed, or `null`. Always one of the fixed sentences below,
  /// never a raw server response, so no credential can leak into the UI.
  String? get errorMessage => _errorMessage;

  /// Signs in with an email and password.
  ///
  /// Returns true when the terminal is now authenticated. On failure it returns false,
  /// leaves the fields for the operator to correct, and sets [errorMessage]. Never throws.
  Future<bool> signIn({required String email, required String password}) async {
    if (!isCloudEnabled || _authClient == null || _session == null) {
      // Nothing to sign in to. Reported as a clear message rather than a silent no-op.
      _fail('Cloud sign-in is not available in this build.');
      return false;
    }
    if (_status == SignInStatus.submitting) {
      return false;
    }

    final String trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      _fail('Enter your email and password.');
      return false;
    }

    _status = SignInStatus.submitting;
    _errorMessage = null;
    _notify();

    final Result<FirebaseAuthTokens> result = await _authClient
        .signInWithPassword(trimmedEmail, password);

    return result.fold(
      onOk: (FirebaseAuthTokens tokens) async {
        // Persist the session first, so a crash between here and the next launch still
        // leaves the terminal signed in rather than dropping the sign-in on the floor.
        await _sessionStore.save(
          refreshToken: tokens.refreshToken,
          email: trimmedEmail,
        );
        // Hand the session to the shared object the sync transport signs its requests
        // with. From here the terminal is authenticated for the cloud.
        _session.adopt(tokens);
        await _syncActivation?.enable();

        _isAuthenticated = true;
        _email = trimmedEmail;
        _status = SignInStatus.idle;
        _errorMessage = null;
        _notify();
        return true;
      },
      onErr: (AppFailure failure) {
        _fail(_messageFor(failure));
        return false;
      },
    );
  }

  /// Signs out of the cloud.
  ///
  /// Clears the in-memory and persisted session and stops synchronisation, so cloud
  /// operations require signing in again. It does **not** delete the local database or the
  /// outbox: local records and any queued changes are preserved for the next session. The
  /// caller is responsible for warning about pending changes before this is called.
  Future<void> signOut() async {
    if (!isCloudEnabled) {
      return;
    }
    // Stop reaching the cloud before forgetting anything, so no in-flight cycle races the
    // sign-out.
    await _syncActivation?.disable();
    _session?.clear();
    await _sessionStore.clear();

    _isAuthenticated = false;
    _email = null;
    _status = SignInStatus.idle;
    _errorMessage = null;
    _notify();
  }

  /// Clears a stale error, for example when the operator starts typing again.
  void clearError() {
    if (_status == SignInStatus.failed) {
      _status = SignInStatus.idle;
      _errorMessage = null;
      _notify();
    }
  }

  void _fail(String message) {
    _status = SignInStatus.failed;
    _errorMessage = message;
    _notify();
  }

  /// Turns a failure into a sentence a cashier can act on, without exposing anything the
  /// server returned. Deliberately does not distinguish "no such user" from "wrong
  /// password" — telling the two apart helps an attacker enumerate accounts.
  static String _messageFor(AppFailure failure) {
    if (failure is NetworkFailure) {
      return 'Can’t reach the cloud. Check your internet connection and try '
          'again. You can keep billing offline in the meantime.';
    }
    // Any server-side refusal: bad credentials, a disabled account, or a project not set
    // up for email sign-in.
    return 'That email and password did not match. Check them and try again.';
  }

  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
