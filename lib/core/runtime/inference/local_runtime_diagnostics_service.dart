import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
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

  // True while a real validation is executing.
  bool _refreshInProgress = false;

  // Shared future prevents concurrent callers from starting multiple
  // validations at the same time.
  Future<LocalRuntimeState>? _activeRefresh;

  DateTime? _lastRefreshAt;
  LocalRuntimeState? _lastRefreshSnapshot;

  // Very short UI/startup burst protection.
  static const Duration _refreshDebounce = Duration(milliseconds: 600);

  // Once the runtime is known to be ready, avoid repeatedly performing
  // filesystem/model/runtime checks for a short period.
  //
  // This is deliberately short: it improves startup/UI responsiveness
  // without making model changes effectively invisible for long periods.
  static const Duration _readyCacheLifetime = Duration(seconds: 8);

  /// Returns `true` when the runtime state indicates that local inference
  /// cannot proceed.
  bool get isBlockedForLocalMode =>
      monitor.state.status == LocalRuntimeStatus.ffiMissing ||
      monitor.state.status == LocalRuntimeStatus.modelMissing ||
      monitor.state.status == LocalRuntimeStatus.failed ||
      monitor.state.status == LocalRuntimeStatus.runtimeUnavailable;

  /// The message from the last completed startup validation.
  String? get startupValidationMessage =>
      _hasRunStartupValidation ? monitor.state.message : null;

  Future<void> validateOnStartup() async {
    if (_hasRunStartupValidation) {
      _log(
        '[RUNTIME_DIAGNOSTICS] startup_validation_skipped reason=already_completed',
      );
      return;
    }

    _hasRunStartupValidation = true;
    await refresh();
  }

  Future<void> refresh() async {
    // Never start another validation while inference is active.
    //
    // This check intentionally happens before acquiring the refresh lock so
    // diagnostics can never interfere with the inference hot path.
    if (_isInferenceActive) {
      _log(
        '[RUNTIME_DIAGNOSTICS] refresh_skipped reason=inference_active',
      );
      return;
    }

    // If another caller is already validating, wait for that same operation
    // instead of silently starting or duplicating another validation.
    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) {
      _log(
        '[RUNTIME_DIAGNOSTICS] refresh_joined reason=validation_in_progress',
      );
      await activeRefresh;
      return;
    }

    final now = DateTime.now();

    // Fast path for a recently completed validation.
    final lastRefresh = _lastRefreshAt;
    final lastSnapshot = _lastRefreshSnapshot;

    if (lastRefresh != null && lastSnapshot != null) {
      final elapsed = now.difference(lastRefresh);

      if (elapsed < _refreshDebounce) {
        _log(
          '[RUNTIME_DIAGNOSTICS] refresh_skipped reason=debounce '
          'elapsed_ms=${elapsed.inMilliseconds} '
          'status=${lastSnapshot.status.name}',
        );
        _publishSnapshot(lastSnapshot);
        return;
      }

      // The runtime is already ready and was checked very recently.
      //
      // Avoid repeating the expensive model/file/runtime validation during
      // normal UI refreshes. A later explicit validation can still occur
      // after the short cache lifetime expires.
      if (lastSnapshot.status == LocalRuntimeStatus.ready &&
          elapsed < _readyCacheLifetime) {
        _log(
          '[RUNTIME_DIAGNOSTICS] refresh_skipped reason=ready_cache '
          'elapsed_ms=${elapsed.inMilliseconds} '
          'cache_ms=${_readyCacheLifetime.inMilliseconds}',
        );
        _publishSnapshot(lastSnapshot);
        return;
      }
    }

    _refreshInProgress = true;

    final refreshFuture = _performRefresh(now);
    _activeRefresh = refreshFuture;

    try {
      await refreshFuture;
    } finally {
      if (identical(_activeRefresh, refreshFuture)) {
        _activeRefresh = null;
      }
      _refreshInProgress = false;
    }
  }

  Future<LocalRuntimeState> _performRefresh(DateTime startedAt) async {
    _lastRefreshAt = startedAt;

    _log(
      '[RUNTIME_DIAGNOSTICS] refresh_begin '
      'provider=${_runtimeProvider.runtimeType}',
    );

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

      _log(
        '[RUNTIME_DIAGNOSTICS] model_resolved '
        'model=${selectedModel?.effectiveRuntimeModelId ?? 'none'}',
      );

      final snapshot = await _runtimeProvider.validateRuntime(
        selectedModel: selectedModel,
      );

      _lastRefreshSnapshot = snapshot;

      _publishSnapshot(snapshot);

      _log(
        '[RUNTIME_DIAGNOSTICS] refresh_complete '
        'status=${snapshot.status.name} '
        'message=${snapshot.message ?? 'none'}',
      );

      return snapshot;
    } catch (error, stackTrace) {
      _log(
        '[RUNTIME_DIAGNOSTICS] refresh_error '
        'error=$error',
      );

      _log(
        '[RUNTIME_DIAGNOSTICS] refresh_error_stack '
        '$stackTrace',
      );

      final snapshot = LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Runtime diagnostics failed: $error',
      );

      _lastRefreshSnapshot = snapshot;
      _publishSnapshot(snapshot);

      return snapshot;
    }
  }

  void _publishSnapshot(LocalRuntimeState snapshot) {
    monitor.update(
      snapshot.status,
      message: snapshot.message,
      tokensGenerated: snapshot.tokensGenerated,
      elapsed: snapshot.elapsed,
      startedAt: snapshot.startedAt,
    );
  }

  bool get _isInferenceActive {
    final stateName = _runtimeProvider.lifecycleRuntimeStateName;

    return stateName == LocalRuntimeStatus.inferencing.name ||
        stateName == LocalRuntimeStatus.streaming.name;
  }

  Future<AiModel?> _loadSelectedModel() async {
    final result = await _localAiRepository.getSelectedModel();
    return result.fold(
      (_) => null,
      (model) => model,
    );
  }

  static void _log(String message) {
    RuntimeEventLog.instance.emit(message);
  }
}
