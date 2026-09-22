import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/auth/domain/services/manager_auth_service.dart';
import 'package:brisko_billing/features/auth/presentation/screens/manager_password_screen.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await settleUi(tester);
  }

  Future<AppDependencies> openManager(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppDependencies deps = TestDependencies.over(database);
    await tester.pumpWidget(BriskoApp(dependencies: deps));
    await settleUi(tester);
    await tap(tester, find.text(PosSection.manager.label).last);
    return deps;
  }

  testWidgets('the sidebar opens the manager password screen', (
    WidgetTester tester,
  ) async {
    await openManager(tester);

    expect(find.byType(ManagerPasswordScreen), findsOneWidget);
    expect(find.text('Manager password'), findsOneWidget);
    expect(find.text('Set password'), findsOneWidget);
    expect(find.text('Current password'), findsNothing);
  });

  testWidgets('setting a password from the sidebar persists it', (
    WidgetTester tester,
  ) async {
    await openManager(tester);

    await tester.enterText(
      find.ancestor(
        of: find.text('New password'),
        matching: find.byType(TextField),
      ),
      '1234',
    );
    await tester.enterText(
      find.ancestor(
        of: find.text('Confirm new password'),
        matching: find.byType(TextField),
      ),
      '1234',
    );
    await tester.pump();
    await tap(tester, find.widgetWithText(FilledButton, 'Set password'));

    expect(find.textContaining('Manager password saved'), findsOneWidget);

    final bool? isSet = await tester.runAsync<bool>(() async {
      final ManagerAuthService auth = ManagerAuthService(
        settings: SqliteSettingsRepository(database: database),
      );
      return (await auth.verifyPassword('1234')).valueOrNull ?? false;
    });
    expect(isSet, isTrue);
  });
}
