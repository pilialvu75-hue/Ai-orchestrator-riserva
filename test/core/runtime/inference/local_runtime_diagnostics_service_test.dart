import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockLocalRuntimeProvider extends Mock implements LocalRuntimeProvider {}
class MockAndroidRuntimeProvider extends Mock
    implements AndroidFfiRuntimeProvider {}

class MockLocalAiRepository extends Mock implements LocalAiRepository {}

void main() {
  late MockLocalRuntimeProvider runtimeProvider;
  late MockAndroidRuntimeProvider androidRuntimeProvider;
  late MockLocalAiRepository localAiRepository;
  late LocalRuntimeMonitor androidMonitor;

  const selectedModel = AiModel(
    id: 'llama_1b',
    displayName: 'Llama 3.2 1B',
    fileName: 'model.gguf',
    downloadUrl: 'https://example.com/model.gguf',
    version: '1.0.0',
    sizeBytes: 42,
    description: 'test',
    isDownloaded: true,
    localPath: '/tmp/model.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  setUp(() {
    runtimeProvider = MockLocalRuntimeProvider();
    androidRuntimeProvider = MockAndroidRuntimeProvider();
    localAiRepository = MockLocalAiRepository();
    androidMonitor = LocalRuntimeMonitor();
  });

  group('LocalRuntimeDiagnosticsService.refresh', () {
    test('skips diagnostics refresh while inference is active', () async {
      when(() => runtimeProvider.lifecycleRuntimeStateName)
          .thenReturn(LocalRuntimeStatus.inferencing.name);

      final service = LocalRuntimeDiagnosticsService(
        runtimeProvider: runtimeProvider,
        localAiRepository: localAiRepository,
      );

      await service.refresh();

      expect(service.monitor.state.status, LocalRuntimeStatus.uninitialized);
      verifyNever(() => localAiRepository.getSelectedModel());
      verifyNever(
        () => runtimeProvider.validateRuntime(selectedModel: selectedModel),
      );
    });

    test('skips diagnostics refresh while runtime is streaming', () async {
      when(() => runtimeProvider.lifecycleRuntimeStateName)
          .thenReturn(LocalRuntimeStatus.streaming.name);

      final service = LocalRuntimeDiagnosticsService(
        runtimeProvider: runtimeProvider,
        localAiRepository: localAiRepository,
      );

      await service.refresh();

      expect(service.monitor.state.status, LocalRuntimeStatus.uninitialized);
      verifyNever(() => localAiRepository.getSelectedModel());
      verifyNever(
        () => runtimeProvider.validateRuntime(selectedModel: selectedModel),
      );
    });

    test('does not run concurrent refresh validations', () async {
      final validationCompleter = Completer<LocalRuntimeState>();
      when(() => runtimeProvider.lifecycleRuntimeStateName)
          .thenReturn(LocalRuntimeStatus.ready.name);
      when(() => localAiRepository.getSelectedModel())
          .thenAnswer((_) async => const Right<Failure, AiModel?>(selectedModel));
      when(() => runtimeProvider.validateRuntime(selectedModel: selectedModel))
          .thenAnswer((_) => validationCompleter.future);

      final service = LocalRuntimeDiagnosticsService(
        runtimeProvider: runtimeProvider,
        localAiRepository: localAiRepository,
      );

      final firstRefresh = service.refresh();
      await Future<void>.delayed(Duration.zero);
      final secondRefresh = service.refresh();

      verify(() => runtimeProvider.validateRuntime(selectedModel: selectedModel))
          .called(1);

      validationCompleter.complete(const LocalRuntimeState(
        status: LocalRuntimeStatus.runtimeUnavailable,
        message: 'not verified',
      ));

      await firstRefresh;
      expect(service.monitor.state.status, LocalRuntimeStatus.runtimeUnavailable);
      await secondRefresh;

      expect(service.monitor.state.status, LocalRuntimeStatus.runtimeUnavailable);
    });

    test('does not downgrade provider-owned READY monitor to runtimeUnavailable',
        () async {
      when(() => androidRuntimeProvider.lifecycleRuntimeStateName)
          .thenReturn(LocalRuntimeStatus.ready.name);
      when(() => androidRuntimeProvider.monitor).thenReturn(androidMonitor);
      when(() => localAiRepository.getSelectedModel())
          .thenAnswer((_) async => const Right<Failure, AiModel?>(selectedModel));
      when(() => androidRuntimeProvider.validateRuntime(selectedModel: selectedModel))
          .thenAnswer((_) async => const LocalRuntimeState(
                status: LocalRuntimeStatus.runtimeUnavailable,
                message: 'transient recheck',
              ));

      final service = LocalRuntimeDiagnosticsService(
        runtimeProvider: androidRuntimeProvider,
        localAiRepository: localAiRepository,
      );

      androidMonitor.update(
        LocalRuntimeStatus.ready,
        message: 'ready',
      );

      await service.refresh();

      expect(service.monitor.state.status, LocalRuntimeStatus.ready);
      verify(() => androidRuntimeProvider.validateRuntime(selectedModel: selectedModel))
          .called(1);
    });
  });
}
