import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_database.dart';
import 'helpers/test_dependencies.dart';

/// Builds the dependency graph against an in-memory database.
///
/// The widget tests drive the real repositories rather than fakes, because the shell
/// has to be able to construct them. Nothing here writes to a real database file.
Future<AppDependencies> _testDependencies() async {
  return TestDependencies.over(await TestDatabase.openInMemory());
}

void main() {
  setUpAll(TestDatabase.register);

  late AppDependencies dependencies;

  setUp(() async {
    dependencies = await _testDependencies();
  });

  tearDown(() async {
    await dependencies.dispose();
  });

  group('PosShell', () {
    testWidgets('starts on the dashboard section', (WidgetTester tester) async {
      await tester.pumpWidget(BriskoApp(dependencies: dependencies));

      // Title in the app bar, plus the section heading.
      expect(find.text(PosSection.dashboard.label), findsWidgets);

      // The dashboard reads the database when shown; let that I/O settle so no sqflite
      // timer outlives the widget tree at teardown.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    });

    testWidgets('the rail fits every section on a short counter display', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(BriskoApp(dependencies: dependencies));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text(PosSection.manager.label), findsWidgets);
      expect(find.text(PosSection.settings.label), findsWidgets);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    });

    testWidgets('navigating the rail swaps the active section', (
      WidgetTester tester,
    ) async {
      // Wide enough to render the navigation rail rather than the bottom bar.
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(BriskoApp(dependencies: dependencies));

      expect(find.text(PosSection.manager.label), findsWidgets);

      await tester.tap(find.text(PosSection.reports.label));
      await tester.pumpAndSettle();

      expect(find.text(PosSection.reports.label), findsWidgets);
      expect(find.text(PosSection.dashboard.label), findsOneWidget);

      // The dashboard is the landing section and reads the database when shown, as does
      // the reports screen. Let that I/O settle so no sqflite timer outlives the widget
      // tree when the test tears down.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    });

    testWidgets('shows the configured outlet name in the app bar', (
      WidgetTester tester,
    ) async {
      // A terminal whose owner has set the business name. The shell must lead with it,
      // taken from the configuration rather than hard-coded.
      final AppDependencies configured = TestDependencies.over(
        await TestDatabase.openInMemory(),
        activeSettings: const PosSettings(businessName: 'Brisko Pizza'),
      );
      addTearDown(configured.dispose);

      await tester.pumpWidget(BriskoApp(dependencies: configured));

      // The outlet name is shown prominently, alongside the section heading beneath it.
      expect(find.text('Brisko Pizza'), findsWidgets);
      expect(find.text(PosSection.dashboard.label), findsWidgets);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    });

    testWidgets('falls back to the default outlet name when none is set', (
      WidgetTester tester,
    ) async {
      // A fresh install configures no name. The shell falls back to the same default the
      // receipt header uses, so the frame is never left without a heading.
      await tester.pumpWidget(BriskoApp(dependencies: dependencies));

      expect(find.text('Brisko Pizza'), findsWidgets);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    });
  });
}
