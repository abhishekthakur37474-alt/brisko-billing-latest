import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/auth/presentation/controllers/auth_controller.dart';
import 'package:brisko_billing/features/auth/presentation/screens/login_screen.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

/// The auth gate decides what the application opens on. These drive the whole
/// `BriskoApp` — the same widget `main` runs — so the login screen, the till and the
/// transition between them are exercised as an operator meets them.
///
/// The sign-in *request* (email/password to Firebase over HTTP) is proven in
/// `auth_controller_test`, which drives it against a loopback server without a widget
/// tree. These tests deliberately do no network: they check the gate's decision and its
/// reaction to the sign-in state changing, which is all the gate itself is responsible
/// for.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;

  setUp(() async {
    database = await TestDatabase.openInMemory();
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  Future<void> settleUi(WidgetTester tester) async {
    for (int round = 0; round < 6; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  AuthController cloudAuth({required bool authenticated}) {
    return AuthController(
      isCloudEnabled: true,
      initiallyAuthenticated: authenticated,
      initialEmail: authenticated ? 'till@brisko.test' : null,
      sessionStore: AuthSessionStore(
        settings: SqliteSettingsRepository(database: database),
      ),
    );
  }

  testWidgets('an unauthenticated cloud terminal opens on the login screen', (
    WidgetTester tester,
  ) async {
    final dependencies = TestDependencies.over(
      database,
      authController: cloudAuth(authenticated: false),
      isCloudConfigured: true,
    );
    addTearDown(dependencies.dispose);

    await tester.pumpWidget(BriskoApp(dependencies: dependencies));
    await settleUi(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    // The till is not shown behind the login screen.
    expect(find.text(PosSection.dashboard.label), findsNothing);
  });

  testWidgets('a terminal with a session opens the till, no network required', (
    WidgetTester tester,
  ) async {
    // The gate opens on the presence of a session, so an offline start with a cached
    // session still reaches the till.
    final dependencies = TestDependencies.over(
      database,
      authController: cloudAuth(authenticated: true),
      isCloudConfigured: true,
    );
    addTearDown(dependencies.dispose);

    await tester.pumpWidget(BriskoApp(dependencies: dependencies));
    await settleUi(tester);

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text(PosSection.dashboard.label), findsWidgets);
  });

  testWidgets('a local-only build opens the till without any login', (
    WidgetTester tester,
  ) async {
    // The default test dependencies are a cloud-disabled build: no project, no gate.
    final dependencies = TestDependencies.over(database);
    addTearDown(dependencies.dispose);

    await tester.pumpWidget(BriskoApp(dependencies: dependencies));
    await settleUi(tester);

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text(PosSection.dashboard.label), findsWidgets);
  });

  testWidgets('signing out returns the terminal to the login screen', (
    WidgetTester tester,
  ) async {
    final AuthController auth = cloudAuth(authenticated: true);
    final dependencies = TestDependencies.over(
      database,
      authController: auth,
      isCloudConfigured: true,
    );
    addTearDown(dependencies.dispose);

    await tester.pumpWidget(BriskoApp(dependencies: dependencies));
    await settleUi(tester);
    expect(find.text(PosSection.dashboard.label), findsWidgets);

    // signOut clears the persisted session, which is real sqflite I/O and so must run in
    // runAsync rather than the widget test's fake-async zone.
    await tester.runAsync(auth.signOut);
    await settleUi(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
