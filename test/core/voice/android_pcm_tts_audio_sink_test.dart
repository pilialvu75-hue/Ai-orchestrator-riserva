import 'dart:typed_data';

import 'package:ai_orchestrator/core/voice/android_pcm_tts_audio_sink.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aivexus_test_pcm_transport');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('PCM16 conversion, append order, pause, resume and true seek calls',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'status') {
        return <String, Object>{
          'supported': true,
          'active': true,
          'playing': false,
          'paused': true,
          'positionMs': 1250,
          'bufferedMs': 8750,
          'complete': false,
        };
      }
      return null;
    });

    final sink = AndroidPcmTtsAudioSink(channel: channel);
    await sink.beginReadAloud();
    sink.push(Float32List.fromList(<double>[-1.0, 0, 1.0]), 24000);
    await sink.finishReadAloud();
    expect(calls.map((call) => call.method).take(3),
        <String>['prepare', 'append', 'finish']);

    final args = calls[1].arguments as Map<Object?, Object?>;
    expect(args['sampleRate'], 24000);
    final pcm = args['pcm'] as Uint8List;
    expect(pcm.length, 6);
    final bytes = ByteData.sublistView(pcm);
    expect(bytes.getInt16(0, Endian.little), -32768);
    expect(bytes.getInt16(2, Endian.little), 0);
    expect(bytes.getInt16(4, Endian.little), 32767);

    final state = await sink.refreshReadAloud();
    expect(state.position, const Duration(milliseconds: 1250));
    expect(state.buffered, const Duration(milliseconds: 8750));
    expect(state.paused, true);
    expect(state.complete, false);

    await sink.pauseReadAloud();
    await sink.resumeReadAloud();
    await sink.skipReadAloud(const Duration(seconds: -10));
    await sink.seekReadAloud(const Duration(seconds: 5));
    await sink.stopReadAloud();

    expect(calls.map((call) => call.method), containsAllInOrder(
      <String>['pause', 'resume', 'seekRelative', 'seek', 'stop']));
    final skip = calls.firstWhere((call) => call.method == 'seekRelative');
    expect((skip.arguments as Map)['milliseconds'], -10000);
    final seek = calls.firstWhere((call) => call.method == 'seek');
    expect((seek.arguments as Map)['milliseconds'], 5000);
  });

  test('unsupported snapshots never fabricate progress', () {
    const state = ReadAloudSnapshot();
    expect(state.supported, false);
    expect(state.position, Duration.zero);
    expect(state.buffered, Duration.zero);
    final invalid = ReadAloudSnapshot.fromMap(<String, Object>{
      'positionMs': -50,
      'bufferedMs': -10,
    });
    expect(invalid.position, Duration.zero);
    expect(invalid.buffered, Duration.zero);
  });
}
