import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Computer Use QA is permission gated and Car Jam only', () {
    final service = File(
      'android/app/src/main/kotlin/com/aiorchestrator/'
      'ComputerUseAccessibilityService.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final settings = File(
      'android/app/src/main/res/xml/computer_use_accessibility.xml',
    ).readAsStringSync();

    expect(service, contains('car.parking.jam.solver.puzzle.games'));
    expect(service, contains('currentPackage != GAME_PACKAGE'));
    expect(service, contains('dispatchGesture('));
    expect(service, contains('INVALID_COORDINATES'));
    expect(service, isNot(contains('performGlobalAction(')));
    expect(manifest, contains('android.permission.BIND_ACCESSIBILITY_SERVICE'));
    expect(settings, contains('android:canPerformGestures="true"'));
  });

  test('QA build opt-in is explicit and normal Android releases remain off', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(workflow, contains('android_computer_use_qa:'));
    expect(workflow, contains('AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA='));
    expect(workflow, contains('OWNER_OPT_IN'));
    expect(workflow, contains('Android CU QA owner only'));
  });

  test('Android lab requires explicit screenshot and gesture permission', () {
    final lab = File(
      'lib/features/computer_use/presentation/computer_use_lab_page.dart',
    ).readAsStringSync();
    expect(lab, contains('Autorizzo questo gesto'));
    expect(lab, contains('openAccessibilitySettings'));
    expect(lab, contains('_session.sessionRevision'));
    expect(lab, contains('tapGame'));
    expect(lab, contains('swipeGame'));
    expect(lab, contains('onPanUpdate'));
    expect(lab, contains('Acquisisci tra 4 secondi'));
  });
}
