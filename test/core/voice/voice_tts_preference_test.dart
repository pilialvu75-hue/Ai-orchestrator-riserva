import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/voice/voice_tts_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(VoiceTtsPreference.channel,
        (MethodCall call) async {
      if (call.method == 'inspect') {
        return <String, Object>{
          'ready': true,
          'voices': <Map<String, String>>[
            <String, String>{'name': 'it-offline', 'language': 'it-IT'},
            <String, String>{'name': 'fr-offline', 'language': 'fr-FR'},
          ],
        };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(VoiceTtsPreference.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Kokoro remains the default and persists explicitly', () async {
    expect(await VoiceTtsPreference.read(), TtsBackend.kokoro);
    await VoiceTtsPreference.save(TtsBackend.kokoro);
    expect(await VoiceTtsPreference.read(), TtsBackend.kokoro);
  });

  test('Android option requires at least one offline voice', () async {
    expect(await VoiceTtsPreference.hasOfflineVoice(language: 'it'), isTrue);
    expect(await VoiceTtsPreference.hasOfflineVoice(language: 'es'), isFalse);
    await VoiceTtsPreference.save(TtsBackend.androidSystem);
    expect(await VoiceTtsPreference.read(), TtsBackend.androidSystem);
  });

  test('missing Android voice never silently changes stored preference', () async {
    messenger.setMockMethodCallHandler(VoiceTtsPreference.channel,
        (MethodCall call) async => <String, Object>{'ready': true, 'voices': <Object>[]});
    await expectLater(
      VoiceTtsPreference.save(TtsBackend.androidSystem),
      throwsStateError,
    );
    expect(await VoiceTtsPreference.read(), TtsBackend.kokoro);
  });

  test('unsupported persisted preference fails closed to Kokoro', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      VoiceTtsPreference.key: 'unknown-future-engine',
    });
    expect(await VoiceTtsPreference.read(), TtsBackend.kokoro);
  });
}
