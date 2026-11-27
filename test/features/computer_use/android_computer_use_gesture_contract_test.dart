import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Computer Use QA binds one gesture to selected external app', () {
    final service = File(
      'android/app/src/main/kotlin/com/aiorchestrator/'
      'ComputerUseAccessibilityService.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final settings = File(
      'android/app/src/main/res/xml/computer_use_accessibility.xml',
    ).readAsStringSync();

    expect(service, contains('selectForegroundTarget'));
    expect(service, contains('currentPackage != selected'));
    expect(service, contains('clearTarget()'));
    expect(service, contains('TARGET_CHANGED_OR_EXPIRED'));
    expect(service, contains('excludedPackages'));
    expect(service, contains('typeInSelectedEditable'));
    expect(service, contains('TARGET_TTL_MS = 180000L'));
    expect(service, contains('FOCUS_ACCESSIBILITY'));
    expect(service, contains('eligibleEditable'));
    expect(service, contains('TEXT_VERIFIED'));
    expect(service, contains('TEXT_NOT_VERIFIED'));
    expect(service, contains('!node.isPassword'));
    expect(service, contains('ACTION_SET_TEXT'));
    expect(service, contains('dispatchGesture('));
    expect(service, contains('INVALID_COORDINATES'));
    expect(service, isNot(contains('performGlobalAction(')));
    expect(manifest, contains('android.permission.BIND_ACCESSIBILITY_SERVICE'));
    expect(settings, contains('android:canPerformGestures="true"'));
    final bridge = File(
      'android/app/src/main/kotlin/com/aiorchestrator/'
      'ComputerUseAndroidBridge.kt',
    ).readAsStringSync();
    expect(bridge, contains('findInstalledApps'));
    expect(bridge, contains('launchInstalledApp'));
    expect(bridge, contains('typeTargetText'));
    expect(bridge, contains('recentVisibleLauncherPackages'));
    expect(bridge, contains('call.method == "swipeTarget"'));
    expect(bridge, isNot(contains('call.method == "swipeGame"')));
    expect(manifest, contains('android.intent.category.LAUNCHER'));
    expect(manifest, isNot(contains('QUERY_ALL_PACKAGES')));
  });

  test('Authorized beta and stable builds expose CU without bypassing consent', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(workflow, contains('android_computer_use_qa:'));
    expect(workflow, contains('AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA='));
    expect(workflow, contains('OWNER_OPT_IN'));
    expect(workflow, contains('Missing trusted owner checkpoint'));
    expect(workflow, contains('owner_checkpoint_run_id'));
    expect(workflow, contains('Authorized release profile: Computer Use ON'));
    expect(workflow, contains('Verify mandatory Computer Use build flag'));
  });

  test('Android lab requires explicit screenshot and gesture permission', () {
    final lab = File(
      'lib/features/computer_use/presentation/computer_use_lab_page.dart',
    ).readAsStringSync();
    expect(lab, contains('Autorizzo questo gesto'));
    expect(lab, contains('openAccessibilitySettings'));
    expect(lab, contains('_session.sessionRevision'));
    expect(lab, contains('tapTarget'));
    expect(lab, contains('swipeTarget'));
    expect(lab, contains('selectForegroundTarget'));
    expect(lab, contains('Cerca e apri app'));
    expect(lab, contains('Inserisci testo nel campo attivo'));
    expect(lab, contains('La selezione dell’app dura 3 minuti'));
    expect(lab, contains('Conferma il contenuto nell’app'));
    expect(lab, contains('onPanUpdate'));
    expect(lab, contains('Acquisisci tra 4 secondi'));
  });
}
