import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:ai_orchestrator/core/voice/sherpa_onnx_voice_engine.dart';

void main() {
  test('Android live ASR requests supported capture-side AEC and NS', () {
    final config = liveAsrRecordConfig(isAndroid: true);
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    expect(config.echoCancel, isTrue);
    expect(config.noiseSuppress, isTrue);
  });

  test('desktop live ASR does not assume platform AEC and NS support', () {
    final config = liveAsrRecordConfig(isAndroid: false);
    expect(config.echoCancel, isFalse);
    expect(config.noiseSuppress, isFalse);
    expect(config.encoder, AudioEncoder.pcm16bits);
  });
}
