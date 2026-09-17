import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/cantiere_first_app_smoke.dart' as first_app_smoke;

void main() {
  test(
    'Cantiere produces a real installable Android counter APK',
    () async {
      final workspace =
          Platform.environment['CANTIERE_FIRST_APP_WORKSPACE']?.trim();

      expect(
        workspace,
        isNotNull,
        reason: 'CANTIERE_FIRST_APP_WORKSPACE must be provided by CI.',
      );
      expect(workspace, isNotEmpty);

      await first_app_smoke.main(<String>[workspace!]);

      expect(
        exitCode,
        anyOf(0, isNull),
        reason: 'The first-app smoke must not set a failing process exit code.',
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
