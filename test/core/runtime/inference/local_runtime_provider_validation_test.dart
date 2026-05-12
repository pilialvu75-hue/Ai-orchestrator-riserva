import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';

void main() {
  group('LocalRuntimeProvider.validateRuntime', () {
    final provider = LocalRuntimeProvider();

    test('returns modelMissing when no model is selected', () async {
      final state = await provider.validateRuntime();
      expect(state.status, LocalRuntimeStatus.modelMissing);
    });

    test('returns runtimeFailed for invalid model metadata', () async {
      const model = AiModel(
        id: 'llama_1b',
        displayName: 'Llama 3.2 1B',
        fileName: 'model.gguf',
        downloadUrl: 'https://example.com/model.gguf',
        version: '1.0.0',
        sizeBytes: 4,
        description: 'test',
        isDownloaded: true,
        localPath: '/tmp/invalid.gguf',
        validationStatus: ModelValidationStatus.invalidModel,
      );

      final state = await provider.validateRuntime(selectedModel: model);
      expect(state.status, LocalRuntimeStatus.runtimeFailed);
    });

    test('returns ready for a supported validated GGUF file', () async {
      final tempDir = await Directory.systemTemp.createTemp('runtime-test-');
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/model.gguf');
      await file.writeAsBytes(const [0x47, 0x47, 0x55, 0x46, 0x00, 0x01]);

      final model = AiModel(
        id: 'llama_1b',
        displayName: 'Llama 3.2 1B',
        fileName: 'model.gguf',
        downloadUrl: 'https://example.com/model.gguf',
        version: '1.0.0',
        sizeBytes: 6,
        description: 'test',
        isDownloaded: true,
        localPath: file.path,
        validationStatus: ModelValidationStatus.validatedOk,
      );

      final state = await provider.validateRuntime(selectedModel: model);
      expect(state.status, LocalRuntimeStatus.ready);
    });
  });
}
