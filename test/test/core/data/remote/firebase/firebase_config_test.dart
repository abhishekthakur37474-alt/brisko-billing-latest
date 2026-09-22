import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The configuration decides whether the terminal even attempts the cloud, so its
/// "configured" test has to be exactly right: enough to sign in, or treated as
/// offline.
void main() {
  group('FirebaseConfig.fromStored', () {
    test('reads the three client-safe keys', () {
      final FirebaseConfig config = FirebaseConfig.fromStored(<String, String?>{
        FirebaseConfig.keyProjectId: 'brisko-pos',
        FirebaseConfig.keyApiKey: 'web-api-key',
        FirebaseConfig.keyRefreshToken: 'refresh-token',
      });
      expect(config.projectId, 'brisko-pos');
      expect(config.apiKey, 'web-api-key');
      expect(config.refreshToken, 'refresh-token');
    });

    test('trims surrounding whitespace', () {
      final FirebaseConfig config = FirebaseConfig.fromStored(<String, String?>{
        FirebaseConfig.keyProjectId: '  brisko-pos  ',
        FirebaseConfig.keyApiKey: ' web-api-key ',
        FirebaseConfig.keyRefreshToken: ' refresh-token ',
      });
      expect(config.projectId, 'brisko-pos');
      expect(config.apiKey, 'web-api-key');
      expect(config.refreshToken, 'refresh-token');
    });
  });

  group('isConfigured', () {
    test('is true only with a project, a key and a session', () {
      const FirebaseConfig full = FirebaseConfig(
        projectId: 'brisko-pos',
        apiKey: 'web-api-key',
        refreshToken: 'refresh-token',
      );
      expect(full.isConfigured, isTrue);
      expect(full.host, FirebaseConfig.rtdbHost);
    });

    test(
      'is false without a session, because the rules would deny it anyway',
      () {
        const FirebaseConfig noSession = FirebaseConfig(
          projectId: 'brisko-pos',
          apiKey: 'web-api-key',
        );
        expect(noSession.isConfigured, isFalse);
        // Nothing to be online with, so the probe has no host.
        expect(noSession.host, isNull);
      },
    );

    test('is false with a project or key missing', () {
      const FirebaseConfig noKey = FirebaseConfig(
        projectId: 'brisko-pos',
        apiKey: '',
        refreshToken: 'refresh-token',
      );
      const FirebaseConfig noProject = FirebaseConfig(
        projectId: '',
        apiKey: 'web-api-key',
        refreshToken: 'refresh-token',
      );
      expect(noKey.isConfigured, isFalse);
      expect(noProject.isConfigured, isFalse);
    });

    test('an empty stored map is unconfigured, i.e. purely local', () {
      final FirebaseConfig config = FirebaseConfig.fromStored(
        const <String, String?>{},
      );
      expect(config.isConfigured, isFalse);
      expect(config.host, isNull);
    });
  });
}
