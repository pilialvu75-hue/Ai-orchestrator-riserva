import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_audio_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aiorchestrator/live_audio_diagnostics');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('capability alone never authorizes microphone interruption', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'aecAvailable': true,
      'noiseSuppressorAvailable': true,
      'aecAttached': false,
      'echoSuppressionVerified': false,
      'automaticBargeInEnabled': false,
    });
    final caps = await const LiveAudioDiagnostics().inspect();
    expect(caps.aecAvailable, isTrue);
    expect(caps.canInterruptFromMicrophone, isFalse);
  });

  test('missing native channel fails closed', () async {
    final caps = await const LiveAudioDiagnostics().inspect();
    expect(caps.canInterruptFromMicrophone, isFalse);
    expect(caps.aecAvailable, isFalse);
  });

  test('requires attached and verified echo cancellation', () {
    final caps = LiveAudioCapabilities.fromMap({
      'aecAvailable': true,
      'aecAttached': true,
      'echoSuppressionVerified': false,
      'automaticBargeInEnabled': true,
    });
    expect(caps.canInterruptFromMicrophone, isFalse);
  });
}
