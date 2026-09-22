import 'package:flutter/material.dart';

import 'app/bootstrap.dart';
import 'app/brisko_app.dart';

/// Entry point for the Brisko Billing POS.
///
/// Start-up is: open and migrate the local database, build the repositories, then
/// run the UI. The database is deliberately ready before the first frame, because a
/// till that renders before it can read its own menu is worse than one that takes a
/// moment longer to appear.
///
/// A failure here is shown on screen rather than left to a console nobody is watching
/// at the counter: a terminal that cannot open its database must say so, with the
/// reason, so the operator can restart or move the installation somewhere writable.
Future<void> main() async {
  try {
    final AppDependencies dependencies = await bootstrap();
    runApp(BriskoApp(dependencies: dependencies));
  } catch (error) {
    runApp(_StartupFailureApp(error: error));
  }
}

/// Shown when the application cannot start at all.
///
/// A bare [MaterialApp] rather than `BriskoApp`: there are no dependencies to provide,
/// because building them is what failed.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brisko Billing',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Brisko Billing could not start.',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The terminal could not open its local database. Restart the '
                    'application. If this keeps happening, move Brisko Billing out '
                    'of a protected folder (for example Program Files) and open it '
                    'again.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    '$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
