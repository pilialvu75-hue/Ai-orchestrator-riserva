import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/cantiere_first_app_smoke.dart' as first_app_smoke;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final workspace =
      Platform.environment['CANTIERE_FIRST_APP_WORKSPACE']?.trim();
  final acceptanceEnabled = workspace != null && workspace.isNotEmpty;

  test(
    'Cantiere prepares the guarded Android counter workspace',
    () async {
      await first_app_smoke.main(<String>[
        workspace!,
        '--prepare-only',
      ]);

      expect(
        exitCode,
        anyOf(0, isNull),
        reason: 'The first-app smoke must not set a failing process exit code.',
      );
    },
    skip: acceptanceEnabled
        ? false
        : 'Runs only in the dedicated Cantiere First App APK workflow.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
