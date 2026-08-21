import 'package:ai_orchestrator/core/config/app/environment_config.dart';

class AppConfig {
  const AppConfig({required this.environment});

  final EnvironmentConfig environment;

  static const AppConfig current = AppConfig(
    environment: EnvironmentConfig.current,
  );
}

class AppConstants {
  const AppConstants._();

  // App Info
  static const String appName = 'AI Orchestrator';

  // Voice Engine - STT (Sherpa-ONNX Zipformer)
  static const String sttEncoderFile = 'encoder.onnx';
  static const String sttDecoderFile = 'decoder.onnx';
  static const String sttJoinerFile = 'joiner.onnx';
  static const String sttTokensFile = 'tokens.txt';

  static const String sttZipformerTarUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2';
  static const int sttZipformerTarExpectedBytes = 223522304;

  // Voice Engine - TTS (VITS Piper Paola)
  static const String ttsModelFile = 'model.onnx';
  static const String ttsTokensFile = 'tts_tokens.txt';
  static const String ttsEspeakDataDir = 'espeak-ng-data';

  static const String ttsPaolaTarUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-it_IT-paola-medium.tar.bz2';
  static const int ttsPaolaTarExpectedBytes = 65000000;
}
