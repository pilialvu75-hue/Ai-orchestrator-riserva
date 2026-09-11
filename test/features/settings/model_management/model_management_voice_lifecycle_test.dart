import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/sherpa_onnx_voice_engine.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_cubit.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_service.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_runtime_manifest.dart';

class _Service extends Mock implements ModelManagementService {}
class _Voice extends Mock implements VoiceEngine {}
class _Sherpa extends Mock implements SherpaOnnxVoiceEngine {}

void main() {
  setUpAll(() => registerFallbackValue((double progress) {}));
  test('repeated model downloads never dispose the shared voice engine', () async {
    final service = _Service();
    final voice = _Voice();
    final direct = _Sherpa();
    final spec = ModelRuntimeManifest.files.first;
    final status = VoiceEngineStatus.unsupported(details: 'test');
    when(() => voice.initialize()).thenAnswer((_) async => status);
    when(() => direct.initialize()).thenAnswer((_) async => status);
    when(() => direct.dispose()).thenAnswer((_) async {});
    when(() => service.forceDownload(spec, onProgress: any(named: 'onProgress')))
        .thenAnswer((_) async => ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.presentInternalStorage,
          path: '/test/model',
        ));
    final cubit = ModelManagementCubit(
      service: service, voiceEngine: voice, directVoiceEngine: direct,
    );
    try {
      await cubit.forceDownload(spec.id);
      await cubit.forceDownload(spec.id);
      verifyNever(() => direct.dispose());
      verifyNever(() => voice.dispose());
      verify(() => direct.initialize()).called(2);
      verify(() => voice.initialize()).called(2);
    } finally {
      await cubit.close();
    }
  });
}
