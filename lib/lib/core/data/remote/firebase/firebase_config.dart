/// Connection details for the Firebase backend, read from local configuration.
///
/// ## Why Firebase
///
/// The wider Brisko ecosystem — and the future customer-facing Android app — already
/// runs on Firebase, so the point-of-sale terminal joins the same cloud rather than
/// standing up a second auth-and-database stack. The local model stays exactly as it
/// was: one row per entity in SQLite, versioned by an `updatedAt` timestamp and
/// soft-deleted by a flag. Realtime Database is a JSON tree, so each entity becomes
/// one node keyed by its stable device id, last-write-wins still falls out of
/// comparing `updatedAt`, and a soft delete is just a node with its flag set.
///
/// ## Why the REST surface rather than the native SDK
///
/// The terminal reaches Realtime Database and Firebase Authentication over their HTTPS
/// APIs through a thin `dart:io` client. That keeps the desktop build free of native
/// plugins and CocoaPods, keeps the dependency list minimal, and lets the whole sync
/// path be tested without a live project. The data and the security rules are identical
/// to what a native-SDK client would see, so an Android app built on FlutterFire shares
/// the same RTDB and the same accounts.
///
/// ## What is safe to hold here
///
/// Only client-safe values. The Firebase project id and the Web API key are designed to
/// ship in client applications; access is controlled by Realtime Database Security
/// Rules on the server, not by keeping these secret. The optional [refreshToken] is a
/// signed-in user's session, exchanged for short-lived ID tokens; it is not a password,
/// and the privileged service-account key is never placed in the application, in
/// configuration or in source.
class FirebaseConfig {
  const FirebaseConfig({
    required this.projectId,
    required this.apiKey,
    this.refreshToken,
    this.databaseUrl = defaultDatabaseUrl,
  });

  /// Reads the configuration from the stored settings map the bootstrap already
  /// loads. Absent keys produce an unconfigured value, which reads as offline.
  factory FirebaseConfig.fromStored(Map<String, String?> stored) {
    return FirebaseConfig(
      projectId: stored[keyProjectId]?.trim() ?? '',
      apiKey: stored[keyApiKey]?.trim() ?? '',
      refreshToken: stored[keyRefreshToken]?.trim(),
    );
  }

  /// Settings key for the Firebase project id, for example `brisko-pos`.
  static const String keyProjectId = 'cloud.firebase.projectId';

  /// Settings key for the Web API key. Client-safe by design.
  static const String keyApiKey = 'cloud.firebase.apiKey';

  /// Settings key for a signed-in user's refresh token, when present. This is the
  /// terminal's session: it is exchanged for a short-lived ID token, never stored as
  /// a password.
  static const String keyRefreshToken = 'cloud.firebase.refreshToken';

  /// Default Realtime Database URL for this project (asia-southeast1).
  static const String defaultDatabaseUrl =
      'https://brisko-billing-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// The host every RTDB request resolves, used by the connectivity probe.
  static const String rtdbHost =
      'brisko-billing-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// The Firebase project id.
  final String projectId;

  /// The Web API key. Client-safe by design; Realtime Database Security Rules are
  /// what actually protect the data.
  final String apiKey;

  /// A signed-in user's refresh token, when the terminal has authenticated. Exchanged
  /// for an ID token whose `uid` is the restaurant the client may read and write.
  final String? refreshToken;

  /// HTTPS root of the Realtime Database, without a trailing slash.
  final String databaseUrl;

  /// True when there is enough to attempt an authenticated connection: a project, a
  /// key, and a session to sign the terminal in. An incomplete configuration is
  /// treated exactly like being offline — local billing is unaffected and nothing is
  /// uploaded until it is completed.
  ///
  /// The refresh token is part of "configured" on purpose. Realtime Database Security
  /// Rules deny an anonymous client everything, so a terminal with no session has no
  /// backend it can actually reach; treating that as "not configured" keeps it cleanly
  /// offline rather than failing every request against the rules.
  bool get isConfigured =>
      projectId.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      (refreshToken?.trim().isNotEmpty ?? false);

  /// Host name of the cloud backend, for the connectivity probe. `null` when the
  /// terminal is not configured, because there is then nothing to be online with.
  String? get host => isConfigured ? rtdbHost : null;
}
