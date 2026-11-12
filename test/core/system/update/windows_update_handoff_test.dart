import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/system/update/assistant_update_gate.dart';
import 'package:ai_orchestrator/core/system/update/windows_update_manager.dart';
import 'package:ai_orchestrator/core/system/update/windows_update_installer.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

class _Checker extends Mock implements UpdateChecker {}
class _Intent extends Mock implements AndroidIntentHandler {}
class _Installer extends Mock implements WindowsUpdateInstallerPort {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Directory temp;
  late SharedPreferences prefs;
  late _Installer installer;
  late AssistantUpdateGate gate;
  late List<String> calls;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('update-handoff-test-');
    SharedPreferences.setMockInitialValues({
      'update_windows_pending_path': '${temp.path}/setup.exe',
      'update_windows_pending_version': '1.0.14',
      'update_windows_pending_size': 10,
      'update_windows_pending_sha256': hash,
    });
    prefs = await SharedPreferences.getInstance();
    gate = AssistantUpdateGate();
    calls = [];
    installer = _Installer();
    when(() => installer.verify(
      filePath: any(named: 'filePath'),
      expectedSizeBytes: any(named: 'expectedSizeBytes'),
      expectedSha256: any(named: 'expectedSha256'),
    )).thenAnswer((_) async {
      calls.add('verify');
      return const WindowsInstallerVerification(
        valid: true, exists: true, sizeBytes: 10, sha256: hash, reason: 'ok');
    });
    when(() => installer.launch(any())).thenAnswer((_) async {
      calls.add('launch');
      expect(gate.isUpdating, isTrue);
      expect(() => gate.beginChat(), throwsStateError);
      return true;
    });
  });

  tearDown(() async { await temp.delete(recursive: true); });

  WindowsUpdateManager manager(Future<bool> Function() exit) =>
    WindowsUpdateManager(
      updateChecker: _Checker(), comparator: const VersionComparator(),
      preferences: prefs, intentHandler: _Intent(), currentVersion: '1.0.13',
      windowsInstaller: installer, updateGate: gate, requestAppExit: exit);

  test('verified installer launches before cancelable exit; chat gate held', () async {
    final subject = manager(() async {
      calls.add('exit');
      expect(gate.isUpdating, isTrue);
      return true;
    });
    expect(await subject.prepareInstallIntent(), isTrue);
    expect(calls, ['verify', 'launch', 'exit']);
    expect(gate.isUpdating, isFalse);
    expect(prefs.getString('update_windows_pending_path'), isNotNull);
    subject.dispose();
  });

  test('active chat including final persistence prevents installer launch', () async {
    final finishChat = gate.beginChat();
    final subject = manager(() async { fail('must not close during chat'); });
    expect(await subject.prepareInstallIntent(), isFalse);
    expect(calls, ['verify']);
    expect(gate.hasActiveChats, isTrue);
    finishChat();
    expect(gate.hasActiveChats, isFalse);
    subject.dispose();
  });

  test('failed launch never requests exit and releases gate', () async {
    when(() => installer.launch(any())).thenAnswer((_) async {
      calls.add('launch');
      return false;
    });
    final subject = manager(() async { fail('failed launch must keep app open'); });
    expect(await subject.prepareInstallIntent(), isFalse);
    expect(calls, ['verify', 'launch']);
    expect(gate.isUpdating, isFalse);
    final finishChat = gate.beginChat();
    finishChat();
    subject.dispose();
  });

  test('cancelled exit keeps update retryable and releases gate', () async {
    final subject = manager(() async { calls.add('exit'); return false; });
    expect(await subject.prepareInstallIntent(), isFalse);
    expect(calls, ['verify', 'launch', 'exit']);
    expect(gate.isUpdating, isFalse);
    expect(prefs.getString('update_windows_pending_path'), isNotNull);
    subject.dispose();
  });

  test('leases are idempotent and update waits for all concurrent chats', () {
    final a = gate.beginChat();
    final b = gate.beginChat();
    a(); a();
    expect(gate.tryBeginUpdate(), isNull);
    b();
    final finishUpdate = gate.tryBeginUpdate();
    expect(finishUpdate, isNotNull);
    expect(gate.tryBeginUpdate(), isNull);
    final release = finishUpdate!;
    release(); release();
    expect(gate.isUpdating, isFalse);
    expect(gate.hasActiveChats, isFalse);
  });
}
