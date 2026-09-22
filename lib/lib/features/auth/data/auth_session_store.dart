import '../../../../core/data/remote/firebase/firebase_config.dart';
import '../../../../core/utils/result.dart';
import '../../settings/domain/repositories/settings_repository.dart';

/// A persisted sign-in, restored at start-up so the operator does not sign in every time
/// the till is opened.
class PersistedSession {
  const PersistedSession({required this.refreshToken, this.email});

  /// The long-lived refresh token, exchanged for short-lived ID tokens. This is the
  /// session — not a password, which is never stored.
  final String refreshToken;

  /// The email the terminal signed in with, kept only to show in Settings. Not a secret,
  /// and never used to authenticate.
  final String? email;
}

/// Reads, writes and clears the terminal's persisted Firebase session.
///
/// ## What is kept, and where
///
/// Only the refresh token and the account email, in the same local settings table as the
/// rest of the terminal's configuration. The refresh token is a session credential, not a
/// password: the password is exchanged for it once, at sign-in, and then discarded — it is
/// never written anywhere. The service-account key and the Firebase private key are not
/// part of the application at all, so there is nothing of that kind to store.
///
/// ## Why the settings table rather than a native secure store
///
/// The whole cloud layer is deliberately free of native plugins so the desktop build needs
/// no CocoaPods and the sync path can be tested without a device. A platform keychain would
/// reintroduce exactly that dependency for a token that, on its own, grants access to
/// nothing: Realtime Database Security Rules require the session to resolve to this restaurant's
/// own `uid`, and the token is useless against any other restaurant's data. Persisting it
/// beside the other local configuration keeps the terminal offline-capable and the design
/// consistent, and it is the same session mechanism Step 17 already used.
///
/// This class never returns the token through any path a log or the UI reads; callers ask
/// only whether a session exists, or hand the whole thing to the auth session.
class AuthSessionStore {
  const AuthSessionStore({required this.settings});

  /// Settings key for the account email shown in Settings. Client-safe; not a credential.
  static const String keyAccountEmail = 'cloud.firebase.accountEmail';

  /// The local settings table, where the session is persisted beside the rest of the
  /// terminal's configuration.
  final SettingsRepository settings;

  /// The persisted session read from [stored], or `null` when the terminal has never
  /// signed in (or has signed out).
  ///
  /// Takes the already-loaded settings map rather than reading again, so the bootstrap can
  /// decide the start-up sign-in state from the single read it already does.
  PersistedSession? fromStored(Map<String, String?> stored) {
    final String? token = stored[FirebaseConfig.keyRefreshToken]?.trim();
    if (token == null || token.isEmpty) {
      return null;
    }
    final String? email = stored[keyAccountEmail]?.trim();
    return PersistedSession(
      refreshToken: token,
      email: (email == null || email.isEmpty) ? null : email,
    );
  }

  /// Persists a sign-in so the next launch is already authenticated.
  ///
  /// Written in one transaction with the rest of the settings machinery, so a save either
  /// records the whole session or none of it.
  Future<Result<void>> save({
    required String refreshToken,
    required String email,
  }) {
    return settings.writeAll(<String, String?>{
      FirebaseConfig.keyRefreshToken: refreshToken,
      keyAccountEmail: email,
    });
  }

  /// Forgets the persisted session on sign-out. Removes only the session keys; every other
  /// setting, and all operational data, is left untouched.
  Future<Result<void>> clear() {
    return settings.writeAll(<String, String?>{
      FirebaseConfig.keyRefreshToken: null,
      keyAccountEmail: null,
    });
  }
}
