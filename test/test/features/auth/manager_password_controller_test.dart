import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/auth/domain/services/manager_auth_service.dart';
import 'package:brisko_billing/features/auth/presentation/controllers/manager_password_controller.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteSettingsRepository settings;
  late ManagerPasswordController controller;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    settings = SqliteSettingsRepository(database: database);
    controller = ManagerPasswordController(
      auth: ManagerAuthService(settings: settings),
    );
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('a fresh terminal has no manager password', () async {
    await controller.load();

    expect(controller.status, ManagerPasswordStatus.loaded);
    expect(controller.isPasswordSet, isFalse);
  });

  test('setting a password stores a hash that later verifies', () async {
    await controller.load();
    controller.editNewPassword('1234');
    controller.editConfirmPassword('1234');

    expect(await controller.save(), isTrue);
    expect(controller.isPasswordSet, isTrue);
    expect(controller.isSaved, isTrue);
    expect(controller.newPassword, isEmpty);

    final ManagerAuthService auth = ManagerAuthService(settings: settings);
    expect((await auth.verifyPassword('1234')).valueOrNull, isTrue);
    expect((await auth.verifyPassword('wrong')).valueOrNull, isFalse);
  });

  test('mismatched confirmation is refused and nothing is stored', () async {
    await controller.load();
    controller.editNewPassword('1234');
    controller.editConfirmPassword('5678');

    expect(await controller.save(), isFalse);
    expect(controller.errorMessage, contains('do not match'));
    expect(
      (await ManagerAuthService(settings: settings).isPasswordSet()).valueOrNull,
      isFalse,
    );
  });

  test('a short password is refused', () async {
    await controller.load();
    controller.editNewPassword('12');
    controller.editConfirmPassword('12');

    expect(await controller.save(), isFalse);
    expect(controller.errorMessage, contains('at least'));
  });

  test('changing the password requires the current one', () async {
    await controller.load();
    controller.editNewPassword('1234');
    controller.editConfirmPassword('1234');
    expect(await controller.save(), isTrue);

    await controller.load();
    expect(controller.isPasswordSet, isTrue);

    controller.editCurrentPassword('wrong');
    controller.editNewPassword('5678');
    controller.editConfirmPassword('5678');
    expect(await controller.save(), isFalse);
    expect(controller.errorMessage, contains('incorrect'));

    final ManagerAuthService auth = ManagerAuthService(settings: settings);
    expect((await auth.verifyPassword('1234')).valueOrNull, isTrue);

    controller.editCurrentPassword('1234');
    controller.editNewPassword('5678');
    controller.editConfirmPassword('5678');
    expect(await controller.save(), isTrue);
    expect((await auth.verifyPassword('5678')).valueOrNull, isTrue);
    expect((await auth.verifyPassword('1234')).valueOrNull, isFalse);
  });
}
