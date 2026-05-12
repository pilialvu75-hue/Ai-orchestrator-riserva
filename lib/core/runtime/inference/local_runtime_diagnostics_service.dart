import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';

class LocalRuntimeDiagnosticsService {
  LocalRuntimeDiagnosticsService({
    required LocalRuntimeProvider runtimeProvider,
    required LocalAiRepository localAiRepository,
  })  : _runtimeProvider = runtimeProvider,
        _localAiRepository = localAiRepository,
        monitor = runtimeProvider is AndroidFfiRuntimeProvider
            ? runtimeProvider.monitor
            : LocalRuntimeMonitor();

  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;

  final LocalRuntimeMonitor monitor;

  bool _hasRunStartupValidation = false;

  Future<void> validateOnStartup() async {
    if (_hasRunStartupValidation) return;
    _hasRunStartupValidation = true;
    await refresh();
  }

  Future<void> refresh() async {
    monitor.update(
      LocalRuntimeStatus.loading,
      message: 'Checking local runtime...',
      tokensGenerated: 0,
      elapsed: Duration.zero,
      startedAt: null,
      resetProgress: true,
    );

    final selectedModel = await _loadSelectedModel();
    final snapshot =
        await _runtimeProvider.validateRuntime(selectedModel: selectedModel);
    monitor.update(
      snapshot.status,
      message: snapshot.message,
      tokensGenerated: snapshot.tokensGenerated,
      elapsed: snapshot.elapsed,
      startedAt: snapshot.startedAt,
    );
  }

  Future<AiModel?> _loadSelectedModel() async {
    final result = await _localAiRepository.getSelectedModel();
    return result.fold((_) => null, (model) => model);
  }
}
