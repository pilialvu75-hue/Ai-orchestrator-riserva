import 'package:ai_orchestrator/core/config/app/app_constants.dart';

abstract class VoiceAsrAdapter {
  Future<bool> initialize();

  bool get isListening;

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  });

  Future<void> stopListening();

  Future<void> dispose();
}
