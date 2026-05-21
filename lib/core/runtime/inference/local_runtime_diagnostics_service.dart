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
  bool _refreshInProgress = false;
  DateTime? _lastRefreshAt;
  LocalRuntimeState? _lastRefreshSnapshot;
  // Collapse same-frame startup/UI diagnostics bursts without delaying normal
  // user-driven refresh actions.
  static const Duration _refreshDebounce = Duration(milliseconds: 600);

  /// Returns `true` when the runtime state indicates that local inference
  /// cannot proceed (model missing, FFI library absent, hard runtime failure,
  /// or an unproven runtime that has not yet completed a real inference run).
  /// UI layers may use this to surface a clear blocking warning
  /// instead of silently accepting a "not ready" state.
  bool get isBlockedForLocalMode =>
      monitor.state.status == LocalRuntimeStatus.ffiMissing ||
      monitor.state.status == LocalRuntimeStatus.modelMissing ||
      monitor.state.status == LocalRuntimeStatus.failed ||
      monitor.state.status == LocalRuntimeStatus.runtimeUnavailable;

  /// The message from the last completed startup validation, or `null` if
  /// validation has not yet run.
  String? get startupValidationMessage =>
      _hasRunStartupValidation ? monitor.state.message : null;

  Future<void> validateOnStartup() async {
    if (_hasRunStartupValidation) return;
    _hasRunStartupValidation = true;
    await refresh();
  }

  Future<void> refresh() async {
    if (_refreshInProgress) return;
    // Intentional ordering: do not acquire refresh lock while an inference
    // stream is active; diagnostics refresh must remain a no-op in that window.
    if (_isInferenceActive) return;
    final now = DateTime.now();
    final sinceLastRefresh = _lastRefreshAt == null
        ? null
        : now.difference(_lastRefreshAt!);
    if (sinceLastRefresh != null &&
        sinceLastRefresh < _refreshDebounce &&
        _lastRefreshSnapshot != null) {
      monitor.update(
        _lastRefreshSnapshot!.status,
        message: _lastRefreshSnapshot!.message,
        tokensGenerated: _lastRefreshSnapshot!.tokensGenerated,
        elapsed: _lastRefreshSnapshot!.elapsed,
        startedAt: _lastRefreshSnapshot!.startedAt,
      );
      return;
    }
    _refreshInProgress = true;
    _lastRefreshAt = now;
    monitor.update(
      LocalRuntimeStatus.loading,
      message: 'Checking local runtime...',
      tokensGenerated: 0,
      elapsed: Duration.zero,
      startedAt: null,
      resetProgress: true,
    );

    try {
      final selectedModel = await _loadSelectedModel();
      final snapshot =
          await _runtimeProvider.validateRuntime(selectedModel: selectedModel);
      _lastRefreshSnapshot = snapshot;
      monitor.update(
        snapshot.status,
        message: snapshot.message,
        tokensGenerated: snapshot.tokensGenerated,
        elapsed: snapshot.elapsed,
        startedAt: snapshot.startedAt,
      );
    } finally {
      _refreshInProgress = false;
    }
  }

  bool get _isInferenceActive {
    final stateName = _runtimeProvider.lifecycleRuntimeStateName;
    return stateName == LocalRuntimeStatus.inferencing.name ||
        stateName == LocalRuntimeStatus.streaming.name;
  }

  Future<AiModel?> _loadSelectedModel() async {
    final result = await _localAiRepository.getSelectedModel();
    return result.fold((_) => null, (model) => model);
  }
}
