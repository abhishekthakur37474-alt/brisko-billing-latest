import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../../core/data/remote/firebase/rtdb_paths.dart';
import '../../../../core/data/remote/firebase/rtdb_rest_client.dart';
import '../../../../core/utils/result.dart';
import '../../../settings/domain/models/setting_keys.dart';
import '../../../settings/domain/repositories/settings_repository.dart';

/// Securely verifies and sets the manager password.
///
/// The live copy is the Realtime Database node
/// `restaurants/{uid}/managerPassword`. The hash is cached in local settings so
/// a bill can still be cancelled while the till is offline. It is never written
/// through the entity outbox or Firestore.
class ManagerAuthService {
  const ManagerAuthService({required this.settings, this.rtdb});

  final SettingsRepository settings;

  /// Present on a signed-in cloud build. Absent on a local-only till.
  final RtdbRestClient? rtdb;

  /// Verifies the provided plaintext password against the stored hash.
  ///
  /// Pulls the RTDB node first when the cloud is reachable so a password set on
  /// another terminal is used immediately. Falls back to the local cache when
  /// the link is down.
  Future<Result<bool>> verifyPassword(String plaintext) async {
    await syncFromRtdb();

    final Result<String?> stored = await settings.readString(
      SettingKeys.managerPassword,
    );
    if (stored.isErr) {
      return Err<bool>(stored.failureOrNull!);
    }

    final String? storedHash = stored.valueOrNull;
    if (storedHash == null || storedHash.isEmpty) {
      return Ok<bool>(false);
    }

    final List<String> parts = storedHash.split(':');
    if (parts.length != 2) {
      return Ok<bool>(false);
    }

    final String salt = parts[0];
    final String hash = parts[1];

    final String computed = _hashPassword(plaintext, salt);
    return Ok<bool>(computed == hash);
  }

  /// Sets the manager password, hashing it securely.
  ///
  /// Writes the hash locally, then PUTs it to RTDB. A network failure still
  /// keeps the local copy so this terminal can authorise cancellations; the
  /// next [syncFromRtdb] retries the upload.
  Future<Result<void>> setPassword(String plaintext) async {
    final String salt = _generateSalt();
    final String hash = _hashPassword(plaintext, salt);
    final String stored = '$salt:$hash';
    final int updatedAt = DateTime.now().toUtc().millisecondsSinceEpoch;

    final Result<void> written = await settings.writeAll(<String, String?>{
      SettingKeys.managerPassword: stored,
      SettingKeys.managerPasswordUpdatedAt: updatedAt.toString(),
    });
    if (written.isErr) {
      return written;
    }

    final RtdbRestClient? cloud = rtdb;
    if (cloud == null) {
      return const Ok<void>(null);
    }

    await cloud.putRestaurantNode(
      RtdbPaths.managerPassword,
      <String, dynamic>{'hash': stored, 'updatedAt': updatedAt},
    );
    return const Ok<void>(null);
  }

  Future<Result<bool>> isPasswordSet() async {
    await syncFromRtdb();

    final Result<String?> stored = await settings.readString(
      SettingKeys.managerPassword,
    );
    if (stored.isErr) {
      return Err<bool>(stored.failureOrNull!);
    }
    final String? storedHash = stored.valueOrNull;
    return Ok<bool>(storedHash != null && storedHash.isNotEmpty);
  }

  /// Last-write-wins between the local cache and the RTDB node.
  ///
  /// A newer RTDB hash overwrites the cache. A newer local hash is uploaded.
  /// Failures are swallowed so a downed link never blocks cancellation.
  Future<void> syncFromRtdb() async {
    final RtdbRestClient? cloud = rtdb;
    if (cloud == null) {
      return;
    }

    final Result<Map<String, Object?>> remote = await cloud.getRestaurantNode(
      RtdbPaths.managerPassword,
    );
    if (remote.isErr) {
      return;
    }

    final Map<String, Object?> node =
        remote.valueOrNull ?? const <String, Object?>{};
    final String? remoteHash = node['hash'] as String?;
    final int remoteUpdatedAt = _asInt(node['updatedAt']) ?? 0;

    final String localHash =
        (await settings.readString(SettingKeys.managerPassword)).valueOrNull ??
        '';
    final int localUpdatedAt =
        (await settings.readInt(SettingKeys.managerPasswordUpdatedAt))
            .valueOrNull ??
        0;

    final bool remoteHasHash = remoteHash != null && remoteHash.isNotEmpty;
    final bool localHasHash = localHash.isNotEmpty;

    if (remoteHasHash && remoteUpdatedAt >= localUpdatedAt) {
      if (remoteHash == localHash && remoteUpdatedAt == localUpdatedAt) {
        return;
      }
      await settings.writeAll(<String, String?>{
        SettingKeys.managerPassword: remoteHash,
        SettingKeys.managerPasswordUpdatedAt: remoteUpdatedAt.toString(),
      });
      return;
    }

    if (localHasHash && (!remoteHasHash || localUpdatedAt > remoteUpdatedAt)) {
      await cloud.putRestaurantNode(RtdbPaths.managerPassword, <String, dynamic>{
        'hash': localHash,
        'updatedAt': localUpdatedAt == 0
            ? DateTime.now().toUtc().millisecondsSinceEpoch
            : localUpdatedAt,
      });
    }
  }

  String _generateSalt() {
    final Random random = Random.secure();
    final List<int> saltBytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64.encode(saltBytes);
  }

  String _hashPassword(String password, String salt) {
    final List<int> bytes = utf8.encode('$salt$password');
    final Digest digest = sha256.convert(bytes);
    return digest.toString();
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
}
