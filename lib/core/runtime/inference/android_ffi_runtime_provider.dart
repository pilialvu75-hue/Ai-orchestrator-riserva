import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

part 'android_ffi_runtime_provider_lifecycle_subsystem.dart';
part 'android_ffi_runtime_provider_native_session_subsystem.dart';
part 'android_ffi_runtime_provider_warmup_subsystem.dart';

// ── FSM Fasi Native/FFI ───────────────────────────────────────────────────────
enum FfiPhase {
  idle,
  sessionCreating,
  generationStarting,
  promptIngestion,
  streamingTokens,
  terminating
}

enum RuntimePhase {
  tokenizing,
  startingGeneration,
  waitingFirstToken,
  streaming,
  completed,
  failed,
  cancelled,
  stalled,
}

// ── Provider ──────────────────────────────────────────────────────────────────

/// Android inference provider that drives GGUF model execution through the
/// llama.cpp C bridge ([libllama_bridge.so]) via [dart:ffi].
///
/// Architecture
/// ─────────────
/// 1. [_ensureLibraryLoaded] opens the bridge library once and binds all
///    symbols into [LlamaBridgeBindings].
/// 2. [streamInference] creates/uses a native RuntimeSession and starts the C
///    background generation thread via `llb_session_start_gen`.
/// 3. The Dart async loop calls `llb_session_poll_token` on each iteration, yielding
///    [Future.delayed(Duration.zero)] between empty polls so the Flutter UI
///    stays responsive.
/// 4. [CancellationToken] is forwarded to `llb_session_cancel`, which signals the
///    native background thread to stop.
///
/// Native library resolution order
/// ────────────────────────────────
/// 1. `libllama_bridge.so` – preferred; thin wrapper built from
///    [native/android/llama_bridge.cpp].
///
/// Build instructions
/// ──────────────────
/// Compile the bridge from `native/android/CMakeLists.txt` and place the
/// resulting `.so` in `android/app/src/main/jniLibs/<abi>/`, or configure
/// `externalNativeBuild` in `android/app/build.gradle` to compile it
/// automatically during `flutter build apk`.
class AndroidFfiRuntimeProvider extends LocalRuntimeProvider {
  AndroidFfiRuntimeProvider({
    RuntimeStateMachine? runtimeStateMachine,
    super.developerModeProvider,
    int maxActiveNativeSessions = 1,
  })  : runtimeStateMachine = runtimeStateMachine ?? RuntimeStateMachine(),
        _developerModeProvider = developerModeProvider ?? (() => false),
        _maxActiveNativeSessions =
            maxActiveNativeSessions < 1 ? 1 : maxActiveNativeSessions;

  static const _logTag = 'AI_RUNTIME';
  static const int _safeMaxTokens = 128;
  // Keep local mobile generations bounded so stalled native loops surface
  // quickly and the UI can return partial text instead of hanging indefinitely.
  static const Duration _generationTimeout = Duration(seconds: 90);
  // If native polling produces no token at all within this window, treat the
  // run as stalled rather than waiting for the full timeout budget.
  // Keep this aligned with native/android/llama_bridge.cpp kNoTokenStallMillis.
  static const Duration _stalledInferenceTimeoutRelease = Duration(seconds: 45);
  static const Duration _stalledInferenceTimeoutDebug = Duration(seconds: 120);
  static const Duration _verificationFirstTokenTimeout = Duration(seconds: 5);
  static const Duration _noTokenProgressTimeout = Duration(seconds: 35);
  static const Duration _startGenerationTimeout = Duration(seconds: 60);
  static const Duration _modelLoadTimeout = Duration(seconds: 60);
  // 2400 polls × 24ms delay ~= 57.6s without token progress.
  // This caps idle polling so llb_session_poll_token() cannot spin forever.
  static const int _maxIdlePollIterations = 2400;
  static const int _maxRepeatedTokenLoop = 96;
  static const int _maxConsecutiveInvalidTokens = 24;
  static const String _warmupPrompt = 'Reply with the single word: OK';
  static const int _warmupMaxTokens = 4;
  static const double _warmupTemperature = 0.1;
  // Soft suppression only: 600ms was chosen to collapse same-frame startup/UI
  // revalidation bursts while still allowing user-driven retries immediately.
  static const Duration _runtimeCheckDebounce = Duration(milliseconds: 600);
  // 1200ms captures tight runtimeUnavailable->loading churn seen in failing
  // traces without flagging normal user pacing as a loop.
  static const Duration _reentryWarnThreshold = Duration(milliseconds: 1200);
  // Emit loop-boundary blocked marker after the third rapid re-entry.
  static const int _reentryLoopBlockThreshold = 3;
  static const String _autoTransitionReason = 'status_update';
  static const int _clearVerificationCallerFrameIndex = 2;
  // Very small GGUF files are usually truncated/corrupted placeholders.
  static const int _minValidModelSizeBytes = 4096;
  static const Set<String> _androidSafeModelIds = <String>{
    LocalInferenceModelIds.llama1b,
    LocalInferenceModelIds.gemma2b,
    LocalInferenceModelIds.gemma2_2bIt,
    LocalInferenceModelIds.deepSeekR1_1_5b,
    LocalInferenceModelIds.qwen3_1_7b,
  };
  
  // Sanity Layer: Tag speciali e di sistema da rilevare e sopprimere all'istante
  static const Set<String> _systemSanityTags = <String>{
    '<|im_start|>',
    '<|im_end|>',
    '&lt;|im_start|&gt;',
    '&lt;|im_end|&gt;',
    '&amp;lt;|im_start|&amp;gt;',
    '&amp;lt;|im_end|&amp;gt;',
    '<|endoftext|>',
    '<think>',
    '</think>',
    '&lt;think&gt;',
    '&lt;/think&gt;',
    '<|EOT|>',
    '<|pinned_banner|>'
  };

  static const String _forensicSelfTestSessionId = 'runtime_self_test';
  static int _printCounter = 0;

  /// Observable runtime status.  UI layers may register listeners here.
  final LocalRuntimeMonitor monitor = LocalRuntimeMonitor();
  final RuntimeVerificationMonitor verificationMonitor =
      RuntimeVerificationMonitor();
  final RuntimeStateMachine runtimeStateMachine;
  final bool Function() _developerModeProvider;

  bool get _isDeveloperMode => _developerModeProvider();

  LlamaFfiLibraryHandle? _libraryHandle;
  LlamaBridgeBindings? _bindings;
  int? _nativeSessionId;
  final int _maxActiveNativeSessions;
  final LinkedHashMap<String, int> _nativeSessionsByModel =
      LinkedHashMap<String, int>();
  bool _loadAttempted = false;
  bool _libraryLoadInProgress = false;
  Future<void> _inferenceTail = Future<void>.value();
  Future<void>? _warmupFuture;
  String? _warmupModelPath;
  // Soft lifecycle-tracking state used strictly for diagnostics:
  // - transitions are monitor status changes (from -> to)
  // - reentry means rapid runtimeUnavailable -> loading cycling
  // - runtime-check flags debounce duplicate verification calls
  // No hard transition blocking is enforced by these fields.
  LocalRuntimeState? _lastRuntimeValidationSnapshot;
  bool _runtimeCheckInProgress = false;
  DateTime? _lastRuntimeCheckAt;
  int _transitionCounter = 0;
  int _activeTransitionId = 0;
  DateTime? _lastTransitionAt;
  String _lastTransitionReason = 'provider_init';
  String _lastTransitionOrigin = 'AndroidFfiRuntimeProvider';
  int _reentryCount = 0;
  bool _streamInferenceEntered = false;
  
  // FSM Interna per il monitoraggio nativo delle fasi
  FfiPhase _currentFfiPhase = FfiPhase.idle;
  RuntimePhase _runtimePhase = RuntimePhase.tokenizing;

  // ── First Token Attempt Isolation ─────────────────────────────────────────
  // Unique ID assigned at the start of every streamInference serial-queue
  // execution. Cleared in the poll-loop finally block. Allows forensic log
  // correlation of the complete first-token path across all boundary events.
  String? _currentFirstTokenAttemptId;
  // True from the moment we enter the poll loop until either the first token
  // is received or the loop exits (timeout, failure, or cancellation).
  // Dart's single-threaded event-loop means no synchronisation is needed;
  // all mutations occur on the same isolate.
  // The flag is cleared eagerly on first-token success (so any code later
  // in the same loop iteration sees the correct value) and also in the
  // poll-loop finally block as a catch-all for every non-success exit path.
  bool _preFirstTokenActive = false;
  // ─────────────────────────────────────────────────────────────────────────
  bool _inVerificationScope = false;
  final Set<String> _activeInferenceSessions = <String>{};
  String? _verifiedRuntimeAbi;
  bool _manualVerificationResetRequested = false;
  int _lastLoopLogAtMs = 0;
  static const int _loopLogThrottleMs = 250;
  int _idleBackoffMs = 24;
  final RuntimeModelPathResolver _pathResolver = const RuntimeModelPathResolver();
  late final _AndroidFfiLifecycleSubsystem _lifecycleSubsystem =
      _AndroidFfiLifecycleSubsystem(this);
  late final _AndroidFfiNativeSessionSubsystem _nativeSessionSubsystem =
      _AndroidFfiNativeSessionSubsystem(this);
  late final _AndroidFfiWarmupSubsystem _warmupSubsystem =
      _AndroidFfiWarmupSubsystem(this);

  static Duration get _firstTokenTimeout =>
      kDebugMode ? _stalledInferenceTimeoutDebug : _stalledInferenceTimeoutRelease;

  @override
  int get activeLifecycleTransitionId => _activeTransitionId;

  @override
  String get lifecycleRuntimeStateName => monitor.state.status.name;

  // ── Library loading ──────────────────────────────────────────────────────────

  bool _ensureLibraryLoaded() {
    _log(
      '[RUNTIME_LOOKUP] stage=ffi_library_load_enter provider=$runtimeType hash=${hashCode.toRadixString(16)}',
    );
    if (_libraryLoadInProgress) {
      _log(
        '[RUNTIME_INIT_RECURSION] scope=android_ffi_runtime_provider.ensureLibraryLoaded hash=${hashCode.toRadixString(16)}',
      );
      return true;
    }
    if (_loadAttempted) return _bindings != null && _libraryHandle != null;
    _libraryLoadInProgress = true;
    _loadAttempted = true;
    try {
      final handle = LlamaFfiLoader.tryLoadBridgeLibrary(log: _log);
      if (handle == null) return false;
      _libraryHandle = handle;
      _bindings = handle.bindings;
      _log('[FORENSIC_BEFORE_INIT_BACKEND]');
      _bindings!.initBackend();
      _log('[FORENSIC_AFTER_INIT_BACKEND]');
      _log(
        '[FFI_INIT] Library loaded: ${LlamaFfiLoader.bridgeLibraryName}'
        ' abi=${LlamaFfiLoader.currentAbiName}',
      );
      return true;
    } finally {
      _libraryLoadInProgress = false;
    }
  }

  @override
  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) async {
    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 189 | Function: validateRuntime() | BEFORE entry',
      );
      // Guard: never mutate the runtime state machine or clear verification while
      // a verification scope is active.  A concurrent diagnostic refresh (e.g.
      // from LocalRuntimeDiagnosticsService.refresh()) must not corrupt the
      // lifecycle state that the verification scope is managing.
      if (_inVerificationScope) {
        _log(
          '[RUNTIME_CHECK_SKIPPED] reason=in_verification_scope origin=AndroidFfiRuntimeProvider.validateRuntime transition_action=ignored',
        );
        return _lastRuntimeValidationSnapshot ?? monitor.state;
      }
      if (_activeInferenceSessions.isNotEmpty ||
          monitor.state.status == LocalRuntimeStatus.inferencing ||
          monitor.state.status == LocalRuntimeStatus.streaming) {
        _log(
          '[RUNTIME_CHECK_SKIPPED] reason=inference_active origin=AndroidFfiRuntimeProvider.validateRuntime transition_action=ignored active_sessions=${_activeInferenceSessions.length}',
        );
        return _lastRuntimeValidationSnapshot ?? monitor.state;
      }
      final now = DateTime.now();
      if (_runtimeCheckInProgress) {
        _log('[RUNTIME_CHECK_SKIPPED] reason=check_already_running origin=AndroidFfiRuntimeProvider.validateRuntime transition_action=ignored');
        return _lastRuntimeValidationSnapshot ?? monitor.state;
      }
      final sinceLastCheck = _lastRuntimeCheckAt == null
          ? null
          : now.difference(_lastRuntimeCheckAt!);
      if (sinceLastCheck != null &&
          sinceLastCheck < _runtimeCheckDebounce &&
          _lastRuntimeValidationSnapshot != null) {
        _log(
          '[RUNTIME_CHECK_SKIPPED] reason=debounced elapsed_ms=${sinceLastCheck.inMilliseconds} origin=AndroidFfiRuntimeProvider.validateRuntime transition_action=delayed',
        );
        return _lastRuntimeValidationSnapshot!;
      }
      _runtimeCheckInProgress = true;
      _lastRuntimeCheckAt = now;
      _log('[RUNTIME_CHECK_BEGIN] origin=AndroidFfiRuntimeProvider.validateRuntime');
      if (!LlamaFfiLoader.isCurrentPlatformSupported) {
        final snapshot = LocalRuntimeState(
          status: LocalRuntimeStatus.failed,
          message:
              'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}). '
              'Only ${LlamaFfiLoader.supportedAbiNames} builds are supported.',
        );
        _syncLifecycleState(
          snapshot.status,
          reason: 'runtime_check_unsupported_abi',
          origin: 'AndroidFfiRuntimeProvider.validateRuntime',
        );
        _lastRuntimeValidationSnapshot = snapshot;
        _runtimeCheckInProgress = false;
        return snapshot;
      }
      if (!_ensureLibraryLoaded()) {
        const snapshot = LocalRuntimeState(
          status: LocalRuntimeStatus.ffiMissing,
          message:
              'libllama_bridge.so is missing for this Android build. Rebuild the native runtime for arm64-v8a or x86_64.',
        );
        _syncLifecycleState(
          snapshot.status,
          reason: 'runtime_check_library_missing',
          origin: 'AndroidFfiRuntimeProvider.validateRuntime',
        );
        _lastRuntimeValidationSnapshot = snapshot;
        _runtimeCheckInProgress = false;
        return snapshot;
      }

      final rawSelectedModelPath = selectedModel?.localPath;
      final selectedModelPath = (rawSelectedModelPath == null ||
              rawSelectedModelPath.trim().isEmpty)
          ? rawSelectedModelPath
          : await _resolveHybridModelPath(rawSelectedModelPath);
      final effectiveSelectedModel =
          selectedModelPath == null || selectedModel == null
              ? selectedModel
              : selectedModel.copyWith(localPath: selectedModelPath);
      if (selectedModelPath != null &&
          selectedModelPath.trim().isNotEmpty &&
          hasVerifiedRuntimeForModel(selectedModelPath) &&
          _verifiedRuntimeAbi != LlamaFfiLoader.currentAbiName) {
        _log(
          '[VERIFICATION_REUSE] model_path=${_normalizePathForLogs(selectedModelPath)} verification_scope=false reason=abi_changed previous_abi=${_verifiedRuntimeAbi ?? 'unknown'} current_abi=${LlamaFfiLoader.currentAbiName}',
        );
        clearRuntimeVerification();
      }

      if (selectedModelPath != null && selectedModelPath.trim().isNotEmpty) {
        markRuntimeVerified(selectedModelPath);
        _verifiedRuntimeAbi = LlamaFfiLoader.currentAbiName;
      }

      // ── FORENSIC: gate-condition snapshot ────────────────────────────────────
      final forensicModelId = selectedModel?.effectiveRuntimeModelId ?? 'null';
      final forensicModelPath = selectedModelPath ?? 'null';
      final forensicVerified = selectedModelPath != null &&
          selectedModelPath.trim().isNotEmpty &&
          hasVerifiedRuntimeForModel(selectedModelPath);
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart'
        ' | Line: 277 | Function: validateRuntime()'
        ' | hasVerifiedRuntimeForModel: $forensicVerified'
        ' | ModelID: $forensicModelId'
        ' | ModelPath: ${_normalizePathForLogs(forensicModelPath)}'
        ' | verifiedAbi: ${_verifiedRuntimeAbi ?? 'null'}'
        ' | currentAbi: ${LlamaFfiLoader.currentAbiName}'
        ' | _verifiedModelPath: ${isRuntimeVerified() ? 'SET' : 'null'}'
        ' | _inVerificationScope: $_inVerificationScope',
      );
      // ─────────────────────────────────────────────────────────────────────────

      try {
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 292 | Function: validateRuntime() | BEFORE calling super.validateRuntime()',
        );
        final snapshot =
            await super.validateRuntime(selectedModel: effectiveSelectedModel);
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 296 | Function: validateRuntime() | AFTER calling super.validateRuntime()',
        );
        _syncLifecycleState(
          snapshot.status,
          reason: 'runtime_check_complete',
          origin: 'AndroidFfiRuntimeProvider.validateRuntime',
        );
        _lastRuntimeValidationSnapshot = snapshot;
        return snapshot;
      } finally {
        _runtimeCheckInProgress = false;
      }
    } catch (e, stackTrace) {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 310 | Function: validateRuntime() | BEFORE rethrow after exception: $e \n $stackTrace',
      );
      rethrow;
    } finally {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 315 | Function: validateRuntime() | AFTER exit',
      );
    }
  }

  bool shouldReuseRuntimeVerification({
    required String modelPath,
  }) {
    final reusable = hasVerifiedRuntimeForModel(modelPath) &&
        _verifiedRuntimeAbi == LlamaFfiLoader.currentAbiName &&
        !_manualVerificationResetRequested;
    if (reusable) {
      // Keep both markers for compatibility with existing log filters/forensics
      // that match one tag or the other.
      _log(
        '[RUNTIME_VERIFICATION_REUSED] model_path=${_normalizePathForLogs(modelPath)} abi=${LlamaFfiLoader.currentAbiName}',
      );
      if (!_inVerificationScope) {
        _log(
          '[VERIFICATION_REUSE] model_path=${_normalizePathForLogs(modelPath)} abi=${LlamaFfiLoader.currentAbiName} verification_scope=false',
        );
        final status = monitor.state.status;
        // These states represent stale/pre-verified snapshots that should be
        // immediately promoted back to `ready` once reusable verification
        // evidence is present.
        if (status == LocalRuntimeStatus.runtimeUnavailable ||
            status == LocalRuntimeStatus.uninitialized ||
            status == LocalRuntimeStatus.failed ||
            status == LocalRuntimeStatus.completed) {
          _updateRuntimeStatus(
            LocalRuntimeStatus.ready,
            message: 'Runtime verification reused and ready for inference.',
            reason: 'verification_reused',
            origin: 'shouldReuseRuntimeVerification',
          );
        } else {
          runtimeStateMachine.markVerified();
        }
      }
    }
    return reusable;
  }

  void requestManualVerificationReset() {
    _manualVerificationResetRequested = true;
    _verifiedRuntimeAbi = null;
    clearRuntimeVerification();
  }

  Future<LocalRuntimeState> validateRuntimeInVerificationScope({
    AiModel? selectedModel,
  }) async {
    final rawModelPath = selectedModel?.localPath;
    final resolvedModelPath =
        rawModelPath == null || rawModelPath.trim().isEmpty
            ? rawModelPath
            : await _resolveHybridModelPath(rawModelPath);
    final effectiveSelectedModel =
        resolvedModelPath == null || selectedModel == null
            ? selectedModel
            : selectedModel.copyWith(localPath: resolvedModelPath);
    return _runInVerificationScope(
      modelPath: resolvedModelPath ?? selectedModel?.localPath,
      action: () async {
        verificationMonitor.update(
          RuntimeVerificationPhase.loading,
          message: 'Checking runtime prerequisites.',
        );
        if (!LlamaFfiLoader.isCurrentPlatformSupported) {
          verificationMonitor.update(
            RuntimeVerificationPhase.failed,
            message: 'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}).',
          );
          return LocalRuntimeState(
            status: LocalRuntimeStatus.failed,
            message:
                'Unsupported Android ABI (${LlamaFfiLoader.currentAbiName}). '
                'Only ${LlamaFfiLoader.supportedAbiNames} builds are supported.',
          );
        }
        if (!_ensureLibraryLoaded()) {
          verificationMonitor.update(
            RuntimeVerificationPhase.failed,
            message: 'libllama_bridge.so missing for current build.',
          );
          return const LocalRuntimeState(
            status: LocalRuntimeStatus.ffiMissing,
            message:
                'libllama_bridge.so is missing for this Android build. Rebuild the native runtime for arm64-v8a or x86_64.',
          );
        }
        verificationMonitor.update(
          RuntimeVerificationPhase.running,
          message: 'Runtime prerequisites verified.',
        );
        return super.validateRuntime(selectedModel: effectiveSelectedModel);
      },
    );
  }

  Future<T> _runInVerificationScope<T>({
    required Future<T> Function() action,
    String? modelPath,
  }) async {
    final previousScopeState = _inVerificationScope;
    _inVerificationScope = true;
    _log(
      '[VERIFICATION_SCOPE_ENTER] verification_scope=true model_path=${modelPath == null ? 'unknown' : _normalizePathForLogs(modelPath)}',
    );
    _log(
      '[VERIFICATION_STATE_ISOLATED] verification_scope=true ui_lifecycle_mutation=false runtime_state_machine_mutation=false',
    );
    _log(
      '[FIRST_TOKEN_VERIFICATION_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'none'}'
      ' model_path=${modelPath == null ? 'unknown' : _normalizePathForLogs(modelPath)}',
    );
    try {
      return await action();
    } finally {
      _inVerificationScope = previousScopeState;
      // After exiting the outermost verification scope, emit the deferred
      // lifecycle state that was suppressed during verification.  This ensures
      // the RuntimeStateMachine reaches `verified` before production inference
      // starts, so the `verified → loading → inferencing` transitions work
      // correctly and the state machine is never stuck in `loading` during an
      // active stream.
      if (!_inVerificationScope &&
          modelPath != null &&
          hasVerifiedRuntimeForModel(modelPath)) {
        _log(
          '[VERIFICATION_SCOPE_DEFERRED_UPDATE] verification_scope=false model_path=${_normalizePathForLogs(modelPath)} status=ready',
        );
        _updateRuntimeStatus(
          LocalRuntimeStatus.ready,
          message: 'Runtime verification passed.',
          resetProgress: true,
          reason: 'verification_scope_exit',
          origin: '_runInVerificationScope',
        );
      }
      _log(
        '[VERIFICATION_SCOPE_EXIT] verification_scope=$_inVerificationScope model_path=${modelPath == null ? 'unknown' : _normalizePathForLogs(modelPath)}',
      );
      _log(
        '[FIRST_TOKEN_VERIFICATION_END] attemptId=${_currentFirstTokenAttemptId ?? 'none'}'
        ' model_path=${modelPath == null ? 'unknown' : _normalizePathForLogs(modelPath)}'
        ' scope_restored=$_inVerificationScope',
      );
    }
  }

  // ── Inference ────────────────────────────────────────────────────────────────

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    try {
      _log(
        '[FORENSIC_PROVIDER_ENTRY] sessionId=${request.sessionId} provider=$runtimeType modelId=${request.modelId} promptLength=${request.prompt.length}',
      );
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 457 | Function: streamInference() | BEFORE entry',
      );
      _log(
        '[FORENSIC_STREAM_ENTRY] sessionId=${request.sessionId} modelId=${request.modelId} promptLength=${request.prompt.length}',
      );
      _log(
        '[STREAM_INFERENCE_ENTER] session=${request.sessionId} provider=$runtimeType hash=${hashCode.toRadixString(16)}',
      );
      _streamInferenceEntered = true;
      _log('[FORENSIC_STREAM_INFERENCE_ACTIVE] streamInferenceEntered=true sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${_currentThreadId()}');
      final controller = StreamController<InferenceResponse>();
      _log('[STREAM_CONTROLLER_CREATED] sessionId=${request.sessionId} modelId=${request.modelId}');
      var firstFfiInvocationAttempted = false;
      var firstFfiInvocationCompleted = false;

      Future<void> fatalEarlyExit(
        String sessionId, {
        required String branch,
        required String reason,
        required String stage,
        String? details,
        InferenceTerminalState state = InferenceTerminalState.failed,
      }) async {
        _log(
          '[FFI_FATAL_EARLY_EXIT] session=$sessionId branch=$branch reason=$reason',
        );
        _log(
          '[FFI_BRANCH_RETURN] session=$sessionId branch=$branch reason=$reason'
          ' first_ffi_attempted=$firstFfiInvocationAttempted first_ffi_completed=$firstFfiInvocationCompleted',
        );
        if (!controller.isClosed) {
          _finishWithRuntimeError(
            controller,
            stage: stage,
            message: reason,
            details: details,
            state: state,
          );
        }
      }

      controller.onCancel = () {
        if (!firstFfiInvocationAttempted) {
          _log(
            '[FFI_BRANCH_RETURN] session=${request.sessionId} branch=stream_listener_cancel'
            ' reason=stream listener detached before first FFI call',
          );
        }
        _log(
          '[FFI_BRANCH] session=${request.sessionId} name=stream_listener_cancel'
          ' first_ffi_attempted=$firstFfiInvocationAttempted',
        );
      };
      _log('[CANCELLATION_HANDLER_REGISTERED] sessionId=${request.sessionId}');

      _log('[ASYNC_CLOSURE_LAUNCH_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${_currentThreadId()} inferenceTailHash=${_inferenceTail.hashCode}');
      runZonedGuarded(() async {
        _log('[ASYNC_CLOSURE_ENTER] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${_currentThreadId()}');
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 508 | Function: streamInference() | BEFORE calling _runInferenceSerially()',
        );
        try {
          await _runInferenceSerially(() async {
            _log('[ACTION_BODY_BEGIN] sessionId=${request.sessionId} modelId=${request.modelId} isolateHash=${_currentThreadId()} ts=${DateTime.now().microsecondsSinceEpoch}');
            final sessionId = request.sessionId.trim().isEmpty
                ? 'unknown'
                : request.sessionId.trim();
            final isVerificationSession = sessionId == _forensicSelfTestSessionId;
            final dartThreadId = _currentThreadId();
            // ── First Token Attempt Isolation: assign attempt ID ──────────────────
            final attemptId =
                'fta_${DateTime.now().microsecondsSinceEpoch}_${sessionId.hashCode.toRadixString(16)}';
            _currentFirstTokenAttemptId = attemptId;
            // Attempt telemetry captured by the unified forensic cleanup boundary.
            var estimatedTokens = 0;
            var pollIterations = 0;
            DateTime? firstTokenAt;

            // Runtime recovery classification captured even when reset happens later.
            var runtimeNeedsReset = false;
            String? runtimeResetReason;
            var runtimeResetRequested = false;

            // Termination classification is cumulative: once detected, flags stay set
            // so ATTEMPT_END reports every condition observed across the attempt.
            var cancellationDetected = false;
            var exceptionDetected = false;
            var terminationReason = 'attempt_incomplete';
            var terminalBoundary = 'stream_scope';
            var firstTokenAttemptClosed = false;
            void classifyFirstTokenTermination({
              required String reason,
              required String boundary,
              bool cancellation = false,
              bool exception = false,
              bool runtimeReset = false,
            }) {
              terminationReason = reason;
              terminalBoundary = boundary;
              cancellationDetected = cancellationDetected || cancellation;
              exceptionDetected = exceptionDetected || exception;
              runtimeResetRequested = runtimeResetRequested || runtimeReset;
            }

            void finalizeFirstTokenAttempt() {
              if (firstTokenAttemptClosed) {
                return;
              }
              firstTokenAttemptClosed = true;
              final endAttemptId = _currentFirstTokenAttemptId ?? attemptId;
              final preFirstTokenActiveAtEnd = _preFirstTokenActive;
              final runtimeResetRequestedAtEnd =
                  runtimeResetRequested || runtimeNeedsReset;
              _log(
                '[FIRST_TOKEN_ATTEMPT_END] attemptId=$endAttemptId'
                ' sessionId=$sessionId generated_tokens=$estimatedTokens'
                ' termination_reason=$terminationReason'
                ' terminal_boundary=$terminalBoundary'
                ' first_token_received=${firstTokenAt != null}'
                ' pre_first_token_active=$preFirstTokenActiveAtEnd'
                ' runtime_reset_requested=$runtimeResetRequestedAtEnd'
                ' cancellation_detected=$cancellationDetected'
                ' exception_detected=$exceptionDetected'
                ' runtime_needs_reset=$runtimeNeedsReset'
                ' reset_reason=${runtimeResetReason ?? 'none'}',
              );
              _preFirstTokenActive = false;
              _currentFirstTokenAttemptId = null;
            }

            _log('[ACTION_VARS_INITIALIZED] sessionId=$sessionId modelId=${request.modelId} attemptId=$attemptId dartThreadId=$dartThreadId isolateHash=${_currentThreadId()} nativeSessionId=${_nativeSessionId ?? 'null'} sessionCacheSize=${_nativeSessionsByModel.length} ts=${DateTime.now().microsecondsSinceEpoch}');
            _log(
              '[FIRST_TOKEN_ATTEMPT_BEGIN] attemptId=$attemptId sessionId=$sessionId'
              ' modelId=${request.modelId} is_verification=$isVerificationSession',
            );
            // ─────────────────────────────────────────────────────────────────────
            _log('[FFI_FLOW_ENTER] session=$sessionId thread_id=$dartThreadId');
            _setPhase(RuntimePhase.tokenizing);
            _log(
              '[RUNTIME_PROVIDER_BRANCH] provider=$runtimeType runtime_mode=local '
              'branch=session_api local_request_available=true session=$sessionId',
            );
            _log('[SESSION] begin session=$sessionId');
            _log(
              '[DART_STREAM_LISTEN] elapsed_ms=0 thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=0 session=$sessionId',
            );
            if (!isVerificationSession && !_claimInferenceSlot(sessionId)) {
              classifyFirstTokenTermination(
                reason: 'recursive_inference_guard',
                boundary: 'recursive_inference_guard',
              );
              _log('[FFI_BRANCH] session=$sessionId name=recursive_inference_guard');
              _log('[SESSION] recursive_guard_triggered session=$sessionId');
              await fatalEarlyExit(
                sessionId,
                branch: 'recursive_inference_guard',
                reason: 'Recursive inference call blocked for session $sessionId.',
                stage: 'recursive_inference_guard',
              );
              _log(
                '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'
                ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',
              );
              return;
            }
            if (isVerificationSession) {
              _log(
                '[VERIFICATION_UI_IGNORED] verification_scope=true reason=skip_activeInferenceSessions_tracking session=$sessionId',
              );
            }
            try {
              if (cancellationToken.isCancelled) {
                classifyFirstTokenTermination(
                  reason: 'preflight_cancellation',
                  boundary: 'cancelled',
                  cancellation: true,
                );
                _log('[FFI_BRANCH] session=$sessionId name=preflight_cancellation');
                await fatalEarlyExit(
                  sessionId,
                  branch: 'preflight_cancellation',
                  reason: 'Inference cancelled before first FFI call.',
                  stage: 'cancelled',
                  state: InferenceTerminalState.cancelled,
                );
                return;
              }
              final rawModelPath = request.modelPath;
              final modelPath = rawModelPath == null || rawModelPath.trim().isEmpty
                  ? rawModelPath
                  : await _resolveHybridModelPath(rawModelPath);
              final modelId = request.modelId;
              _log('[CONTEXT] session=$sessionId lines=${request.context.length}'
                  ' system_prompt=${(request.systemPrompt ?? '').trim().isNotEmpty}');

              // ── MODEL PATH FORENSICS ─────────────────────────────────────────────────
              _log('[MODEL_PATH] modelId=$modelId path=${modelPath ?? "(null)"}'
                  ' runtimeMode=android_ffi');
              if (rawModelPath != null &&
                  modelPath != null &&
                  rawModelPath.trim() != modelPath.trim()) {
                _log(
                  '[MODEL_PATH_RESOLVED] original=${_normalizePathForLogs(rawModelPath)} resolved=${_normalizePathForLogs(modelPath)}',
                );
              }

              if (modelPath == null || modelPath.isEmpty || modelId == null) {
                classifyFirstTokenTermination(
                  reason: 'request_validation_missing_path_or_id',
                  boundary: 'request_validation',
                );
                _log('[FFI_BRANCH] session=$sessionId name=request_validation_missing_path_or_id');
                _log('[MODEL_PATH] ABORT: path or modelId is null/empty');
                _log('[TERMINAL_STATE] state=modelMissing reason=missing_path_or_id');
                clearRuntimeVerification();
                _updateRuntimeStatus(
                  LocalRuntimeStatus.modelMissing,
                  message: 'No validated local model is selected.',
                );
                await fatalEarlyExit(
                  sessionId,
                  branch: 'request_validation_missing_path_or_id',
                  reason: 'Missing local model path.',
                  stage: 'request_validation',
                );
                return;
              }

              // Log file existence / size / readability before any guard.
              final modelFile = File(modelPath);
              final modelExists = modelFile.existsSync();
              _log('[MODEL_EXISTS] path=$modelPath exists=$modelExists');
              if (modelExists) {
                int modelSizeBytes = -1;
                bool modelReadable = false;
                try {
                  modelSizeBytes = modelFile.lengthSync();
                  modelReadable = modelSizeBytes > 0;
                } catch (e) {
                  modelReadable = false;
                }
                _log('[MODEL_SIZE] path=$modelPath size_bytes=$modelSizeBytes');
                _log('[MODEL_READABLE] path=$modelPath readable=$modelReadable');
              } else {
                _log('[MODEL_SIZE] path=$modelPath size_bytes=N/A (file not found)');
                _log('[MODEL_READABLE] path=$modelPath readable=false (file not found)');
              }

              if (!_androidSafeModelIds.contains(modelId)) {
                if (_isDeveloperMode) {
                  // Developer mode: warn but allow the run to proceed.
                  _log(
                    '[VALIDATION] developer_mode=true: modelId=$modelId is not in the '
                    'validated set – unsupported quantization or architecture possible. '
                    'Proceeding with experimental inference.',
                  );
                  _updateRuntimeStatus(
                    LocalRuntimeStatus.runtimeUnavailable,
                    message:
                        '[DEVELOPER MODE] $modelId is experimental – compatibility not guaranteed.',
                  );
                  _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=developer_mode_unvalidated_model modelId=$modelId');
                } else {
                  classifyFirstTokenTermination(
                    reason: 'unsupported_model_guard',
                    boundary: 'model_guard',
                  );
                  _log('[FFI_BRANCH] session=$sessionId name=unsupported_model_guard');
                  clearRuntimeVerification();
                  const unsupportedAndroidModelMessage =
                      'Selected model is not enabled for Android local runtime. '
                      'Use DeepSeek-R1-Distill-Qwen-1.5B, Qwen3-1.7B, '
                      'gemma-2-2b-it, llama_1b, or gemma_2b.';
                  _log('[TERMINAL_STATE] state=failed reason=unsupported_model modelId=$modelId');
                  _updateRuntimeStatus(
                    LocalRuntimeStatus.failed,
                    message: unsupportedAndroidModelMessage,
                  );
                  await fatalEarlyExit(
                    sessionId,
                    branch: 'unsupported_model_guard',
                    reason: unsupportedAndroidModelMessage,
                    stage: 'model_guard',
                    details: 'modelId=$modelId',
                  );
                  return;
                }
              }

              // Model file validation runs synchronously on the current isolate.
              _log('[MODEL_VALIDATION_BEGIN] session=$sessionId task=model_validation');
              String? modelValidationError;
              try {
                modelValidationError = _validateModelFileForRuntime(modelPath);
                _log('[MODEL_VALIDATION_OK] session=$sessionId task=model_validation');
              } catch (error, stackTrace) {
                classifyFirstTokenTermination(
                  reason: 'model_validation_failed_unexpected',
                  boundary: 'model_validation',
                  exception: true,
                );
                _log('[MODEL_VALIDATION_FAIL] session=$sessionId task=model_validation error=$error');
                _log('[FFI_EXCEPTION] session=$sessionId stage=model_validation stack=$stackTrace');
                await fatalEarlyExit(
                  sessionId,
                  branch: 'model_validation_failed_unexpected',
                  reason: 'Model validation threw unexpectedly before first FFI call: $error',
                  stage: 'model_validation',
                  details: '$stackTrace',
                );
                return;
              }
              if (modelValidationError != null) {
                classifyFirstTokenTermination(
                  reason: 'model_validation_failed',
                  boundary: 'model_validation',
                );
                _log('[FFI_BRANCH] session=$sessionId name=model_validation_failed');
                _log('[GGUF] validation=failed path=$modelPath reason=$modelValidationError');
                _log('[TERMINAL_STATE] state=failed reason=model_validation'
                    ' path=$modelPath error=$modelValidationError');
                clearRuntimeVerification();
                _updateRuntimeStatus(
                  LocalRuntimeStatus.failed,
                  message: modelValidationError,
                );
                await fatalEarlyExit(
                  sessionId,
                  branch: 'model_validation_failed',
                  reason: modelValidationError,
                  stage: 'model_validation',
                );
                return;
              }
              _log('[GGUF] validation=ok path=$modelPath');

              final isForensicSelfTest =
                  request.sessionId.trim() == _forensicSelfTestSessionId;
              if (!isForensicSelfTest) {
                _log('[FORENSIC_BEFORE_WARMUP]');
                _log(
                  '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 689 | Function: streamInference() | BEFORE calling _ensureWarmup()',
                );
                final warmupReady = await _ensureWarmup(
                  sessionId: sessionId,
                  modelPath: modelPath,
                );
                _log('[FORENSIC_AFTER_WARMUP]');
                _log(
                  '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 696 | Function: streamInference() | AFTER calling _ensureWarmup()',
                );
                if (!warmupReady) {
                  _log('[FFI_BRANCH] session=$sessionId name=warmup_failed_non_blocking_continue');
                }
              } else {
                _log('[WARMUP] skip session=$sessionId reason=self-test owns first token contract');
              }

              if (!_ensureLibraryLoaded()) {
                classifyFirstTokenTermination(
                  reason: 'library_load_failed',
                  boundary: 'library_load',
                );
                _log('[FFI_BRANCH] session=$sessionId name=library_load_failed');
                _log('[TERMINAL_STATE] state=ffiMissing reason=library_load_failed');
                clearRuntimeVerification();
                _updateRuntimeStatus(
                  LocalRuntimeStatus.ffiMissing,
                  message:
                      'libllama_bridge.so is missing for this Android build.',
                );
                await fatalEarlyExit(
                  sessionId,
                  branch: 'library_load_failed',
                  reason: 'Local AI runtime library (libllama_bridge.so) not found.',
                  stage: 'library_load',
                );
                return;
              }

              final bindings = _bindings!;

              // ── Step 1: Create/validate native session ───────────────────────────────
              _updateRuntimeStatus(LocalRuntimeStatus.loading,
                  message: 'Loading model: $modelId', resetProgress: true);
              // Let UI observers process the loading state before the blocking FFI call.
              await Future<void>.delayed(Duration.zero);
              _logAi('creating native session...');
              _log('[NATIVE_MODEL_LOAD_BEGIN] path=$modelPath modelId=$modelId'
                  ' n_ctx=${LlamaNativeDefaults.nCtx} n_threads=${LlamaNativeDefaults.nThreads}'
                  ' gpu_layers=${LlamaNativeDefaults.nGpuLayers}');

              int nativeSessionId;
              try {
                _setPhase(RuntimePhase.tokenizing);
                _log('[FIRST_FFI_CALL_BEGIN] stage=session_create phase=$_currentFfiPhase');
                _log('[FFI_PRE_CREATE_SESSION] session=$sessionId path=$modelPath');
                _log(
                  '[FORENSIC_BEFORE_CREATE_SESSION] sessionId=$sessionId modelId=$modelId modelPath=$modelPath',
                );
                _log(
                  '[FIRST_TOKEN_SESSION_CREATE_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                  ' sessionId=$sessionId modelId=$modelId',
                );
                // This flag marks the first native entry point for this inference flow.
                firstFfiInvocationAttempted = true;
                _log('[FFI_CREATE_SESSION] path=$modelPath');
                nativeSessionId = await _runNativeCallWithTimeout<int>(
                  stage: 'session_create',
                  timeout: _modelLoadTimeout,
                  call: () => _ensureNativeSession(
                    bindings,
                    modelPath,
                    modelId: modelId,
                  ),
                );
                _log(
                  '[FORENSIC_AFTER_CREATE_SESSION] nativeSessionId=$nativeSessionId',
                );
                _log(
                  '[FIRST_TOKEN_SESSION_CREATE_END] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                  ' sessionId=$sessionId nativeSessionId=$nativeSessionId',
                );
                firstFfiInvocationCompleted = true;
                _log('[FFI_POST_CREATE_SESSION] session=$sessionId native_session=$nativeSessionId');
              } catch (error) {
                classifyFirstTokenTermination(
                  reason: error is TimeoutException
                      ? 'session_create_timeout'
                      : 'session_create_exception',
                  boundary: 'session_create',
                  exception: true,
                );
                _log('[FFI_EXCEPTION] session=$sessionId stage=session_create error=$error');
                _log('[SESSION_CREATE_FAIL] path=$modelPath exception=$error');
                _log('[TERMINAL_STATE] state=failed reason=session_create_exception');
                clearRuntimeVerification();
                _updateRuntimeStatus(
                  error is TimeoutException
                      ? LocalRuntimeStatus.timedOut
                      : LocalRuntimeStatus.failed,
                  message: error is TimeoutException
                      ? 'Session create timed out.'
                      : 'Session create failed: $error',
                );
                _finishWithRuntimeError(
                  controller,
                  stage: 'session_create',
                  message: 'Session create failed.',
                  details: error.toString(),
                );
                return;
              }
              _log('[SESSION_CREATE_OK] session=$nativeSessionId path=$modelPath');
              _log('[FFI_CREATE_SESSION_OK] session=$nativeSessionId path=$modelPath');
              final activeAfterCreate = bindings.sessionIsActive(nativeSessionId);
              _log('[NATIVE_MODEL_LOAD_RESULT] llb_session_is_active after create: $activeAfterCreate');

              if (nativeSessionId <= 0 || activeAfterCreate != 1) {
                classifyFirstTokenTermination(
                  reason: 'session_create_invalid_or_inactive',
                  boundary: 'session_create',
                );
                _log('[FFI_BRANCH] session=$sessionId name=session_create_invalid_or_inactive');
                final errMsg = _safeLastError(bindings, nativeSessionId);
                _log('[SESSION_CREATE_FAIL] code=$nativeSessionId error=$errMsg path=$modelPath');
                _log('[TERMINAL_STATE] state=failed reason=session_create_error code=$nativeSessionId');
                clearRuntimeVerification();
                _updateRuntimeStatus(LocalRuntimeStatus.failed, message: errMsg);
                _finishWithRuntimeError(
                  controller,
                  stage: 'session_create',
                  message: 'Failed to create runtime session.',
                  details: 'Create failed with code $nativeSessionId: $errMsg',
                );
                return;
              }
              _log('[NATIVE_MODEL_LOAD_SUCCESS] path=$modelPath modelId=$modelId'
                  ' session=$nativeSessionId');
              _log('[NATIVE_CONTEXT_CREATE] path=$modelPath status=ok');
              _logAi('native session ready');

              // ── Step 2: Start generation ─────────────────────────────────────────────
              final prompt = _composePrompt(
                request,
                modelId: modelId,
                bypassNonessentialLayers: isForensicSelfTest,
              );
              final promptWordEstimate = prompt
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((token) => token.isNotEmpty)
                  .length;
              if (promptWordEstimate <= 0) {
                classifyFirstTokenTermination(
                  reason: 'tokenizer_readiness_failed',
                  boundary: 'tokenizer_readiness',
                );
                _log('[FFI_BRANCH] session=$sessionId name=tokenizer_readiness_failed');
                clearRuntimeVerification();
                _updateRuntimeStatus(
                  LocalRuntimeStatus.failed,
                  message: 'Tokenizer readiness check failed: prompt has no tokens.',
                );
                _finishWithRuntimeError(
                  controller,
                  stage: 'tokenizer_readiness',
                  message: 'Tokenizer readiness check failed before inference.',
                );
                return;
              }
              _updateRuntimeStatus(
                LocalRuntimeStatus.tokenizing,
                message: 'Tokenizing...',
                resetProgress: true,
              );
              _log('[TOKENIZER] status=begin prompt_chars=${prompt.length}');
              _log(
                '[TOKEN_COUNT] prompt_word_estimate=$promptWordEstimate prompt_chars=${prompt.length}',
              );
              _log('[TOKENIZER_OK] prompt_word_estimate=$promptWordEstimate');
              _log(
                '[MODEL_EXECUTION] tokenization start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
              );
              _log(
                '[CONTEXT_SIZE] session=$sessionId context_lines=${request.context.length} system_chars=${(request.systemPrompt ?? '').length} prompt_chars=${request.prompt.length} composed_prompt_chars=${prompt.length}',
              );
              _log('[KV_CACHE] layer=native status=managed_by_llama_bridge');
              _log(
                '[PROMPT_EVAL] stage=start prompt_chars=${prompt.length} prompt_word_estimate=$promptWordEstimate',
              );
              final requestedMaxTokens = isForensicSelfTest ? 4 : request.maxTokens;
              final maxTokens = requestedMaxTokens.clamp(1, _safeMaxTokens);
              final effectiveTemperature = isForensicSelfTest ? 0.1 : request.temperature;
              final effectiveTopK = isForensicSelfTest ? 1 : LlamaNativeDefaults.topK;
              final effectiveTopP = isForensicSelfTest ? 0.1 : LlamaNativeDefaults.topP;
              final firstTokenDeadline =
                  isForensicSelfTest ? _verificationFirstTokenTimeout : _firstTokenTimeout;
              if (request.maxTokens > _safeMaxTokens) {
                _log(
                  '[MODEL_EXECUTION] requested max_tokens=${request.maxTokens} exceeds safe limit; clamped to $maxTokens',
                );
              }

              // Verify that the native session is active before starting generation.
              final loadedCheck = bindings.sessionIsActive(nativeSessionId);
              _log('[MODEL_EXECUTION] llb_session_is_active before start_generation: $loadedCheck');
              if (loadedCheck != 1) {
                classifyFirstTokenTermination(
                  reason: 'session_inactive_before_start',
                  boundary: 'start_generation_preflight',
                );
                _log('[FFI_BRANCH] session=$sessionId name=session_inactive_before_start');
                clearRuntimeVerification();
                final nativeErr = _safeLastError(bindings, nativeSessionId);
                _updateRuntimeStatus(
                  LocalRuntimeStatus.failed,
                  message: 'Session inactive (llb_session_is_active=$loadedCheck).',
                );
                _finishWithRuntimeError(
                  controller,
                  stage: 'start_generation',
                  message:
                      'Session is not active in the native runtime (llb_session_is_active=$loadedCheck).',
                  details: nativeErr.isNotEmpty ? nativeErr : null,
                );
                return;
              }

              _log(
                '[FFI_START_GEN] entering startGeneration session=$nativeSessionId '
                'prompt_chars=${prompt.length} max_tokens=$maxTokens '
                'temperature=$effectiveTemperature',
              );
              _log(
                '[GENERATION_START] session=$sessionId prompt_chars=${prompt.length}'
                ' max_tokens=$maxTokens temperature=$effectiveTemperature'
                ' n_threads=${LlamaNativeDefaults.nThreads}'
                ' n_batch=${LlamaNativeDefaults.nBatch}'
                ' n_ctx=${LlamaNativeDefaults.nCtx}'
                ' top_k=$effectiveTopK'
                ' top_p=$effectiveTopP',
              );
              _logAi('starting inference...');

              // Allocate the prompt pointer here and keep it alive until the first
              // token is received from pollToken.
              final promptNativePtr = prompt.toNativeUtf8(allocator: calloc);
              Pointer<Utf8>? promptNativePtrOrNull = promptNativePtr;
              void freePromptNativePtr() {
                final ptr = promptNativePtrOrNull;
                if (ptr != null) {
                  calloc.free(ptr);
                  promptNativePtrOrNull = null;
                }
              }

              int startResult;
              final startupWatch = Stopwatch()..start();
              try {
                _setPhase(RuntimePhase.startingGeneration);
                final nativeHandleHex =
                    '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
                final nativeHandleAddress =
                    nativeSessionId > 0 ? Pointer<Void>.fromAddress(nativeSessionId).address : 0;
                final activeBeforeStart = bindings.sessionIsActive(nativeSessionId);
                _log(
                  '[FORENSIC_BEFORE_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$modelPath'
                  ' sessionId=$sessionId nativeSessionId=$nativeSessionId phase=$_currentFfiPhase'
                  ' pointer_hex=$nativeHandleHex pointer_address=$nativeHandleAddress'
                  ' session_active=$activeBeforeStart isolateHash=${_currentThreadId()}'
                  ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
                  ' prompt_pointer_hex=0x${promptNativePtr.address.toUnsigned(64).toRadixString(16)}'
                  ' prompt_pointer_address=${promptNativePtr.address}',
                );
                _log('[FFI_PRE_START] session=$sessionId native_session=$nativeSessionId');
                _log('[FORENSIC_BEFORE_START_GENERATION] sessionId=$sessionId nativeSessionId=$nativeSessionId');
                _log(
                  '[FIRST_TOKEN_START_GENERATION_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                  ' sessionId=$sessionId nativeSessionId=$nativeSessionId',
                );
                startResult = await _runNativeCallWithTimeout<int>(
                  stage: 'start_generation',
                  timeout: _startGenerationTimeout,
                  call: () => bindings.startGeneration(
                    nativeSessionId,
                    promptNativePtr,
                    maxTokens,
                    effectiveTemperature,
                  ),
                );
                _log('[FORENSIC_AFTER_START_GENERATION] sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult');
                final activeAfterStart = bindings.sessionIsActive(nativeSessionId);
                _log(
                  '[FORENSIC_AFTER_LLB_SESSION_START_GEN] modelId=$modelId modelPath=$modelPath'
                  ' sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult'
                  ' pointer_hex=$nativeHandleHex pointer_address=$nativeHandleAddress'
                  ' session_active=$activeAfterStart isolateHash=${_currentThreadId()}'
                  ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
                  ' prompt_pointer_hex=0x${promptNativePtr.address.toUnsigned(64).toRadixString(16)}'
                  ' prompt_pointer_address=${promptNativePtr.address}',
                );
                _log(
                  '[FIRST_TOKEN_START_GENERATION_END] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                  ' sessionId=$sessionId nativeSessionId=$nativeSessionId startResult=$startResult',
                );
                _log(
                  '[FFI_POST_START] session=$sessionId native_session=$nativeSessionId result=$startResult'
                  ' elapsed_ms=${startupWatch.elapsedMilliseconds}',
                );
              } catch (error) {
                startupWatch.stop();
                freePromptNativePtr();
                classifyFirstTokenTermination(
                  reason: error is TimeoutException
                      ? 'start_generation_timeout'
                      : 'start_generation_exception',
                  boundary: 'start_generation',
                  exception: true,
                  runtimeReset: true,
                );
                _log('[FFI_EXCEPTION] session=$sessionId stage=start_generation error=$error');
                clearRuntimeVerification();
                _setPhase(RuntimePhase.failed);
                _safeResetRuntime(bindings, reason: 'start_generation_exception');
                _updateRuntimeStatus(
                  error is TimeoutException
                      ? LocalRuntimeStatus.timedOut
                      : LocalRuntimeStatus.failed,
                  message: error is TimeoutException
                      ? 'Native start_generation timed out.'
                      : 'Native start_generation failed: $error',
                );
                if (error is TimeoutException) {
                  _log(
                    '[FFI_TIMEOUT] session=$sessionId stage=start_generation'
                    ' timeout_ms=${_startGenerationTimeout.inMilliseconds}',
                  );
                }
                _finishWithRuntimeError(
                  controller,
                  stage: 'start_generation',
                  message: error is TimeoutException
                      ? 'Native generation start timed out.'
                      : 'Native generation start failed.',
                  details: error.toString(),
                );
                return;
              }
              startupWatch.stop();
              _log('[MODEL_EXECUTION] llb_session_start_gen returned: $startResult');

              if (startupWatch.elapsed > _startGenerationTimeout) {
                classifyFirstTokenTermination(
                  reason: 'start_generation_timeout',
                  boundary: 'start_generation_postcheck',
                  runtimeReset: true,
                );
                _log(
                  '[FFI_TIMEOUT] session=$sessionId stage=start_generation_postcheck'
                  ' timeout_ms=${_startGenerationTimeout.inMilliseconds}',
                );
                freePromptNativePtr();
                _safeCancel(bindings, nativeSessionId);
                clearRuntimeVerification();
                _setPhase(RuntimePhase.stalled);
                _safeResetRuntime(bindings, reason: 'start_generation_timeout');
                _updateRuntimeStatus(
                  LocalRuntimeStatus.timedOut,
                  message:
                      'Inference startup timed out after ${_startGenerationTimeout.inSeconds}s.',
                );
                _logAi('inference timeout');
                _finishWithRuntimeError(
                  controller,
                  stage: 'start_generation',
                  message:
                      'Inference startup timed out after ${_startGenerationTimeout.inSeconds}s.',
                );
                return;
              }

              if (startResult != 0) {
                classifyFirstTokenTermination(
                  reason: 'start_generation_failed_code',
                  boundary: 'start_generation',
                  runtimeReset: true,
                );
                _log('[FFI_BRANCH] session=$sessionId name=start_generation_failed_code');
                freePromptNativePtr();
                clearRuntimeVerification();
                _setPhase(RuntimePhase.failed);
                final err = _safeLastError(bindings, nativeSessionId);
                _safeResetRuntime(bindings, reason: 'start_generation_failed');
                _updateRuntimeStatus(LocalRuntimeStatus.failed, message: err);
                _finishWithRuntimeError(
                  controller,
                  stage: 'start_generation',
                  message: 'Failed to start generation.',
                  details: err,
                );
                return;
              }
              _log('[WARMUP] inference_startup_ok session=$sessionId'
                  ' startup_ms=${startupWatch.elapsed.inMilliseconds}');
              _log(
                '[PROMPT_EVAL] stage=ready startup_ms=${startupWatch.elapsed.inMilliseconds}',
              );

              cancellationToken.onCancel(() => _safeCancel(bindings, nativeSessionId));

              // ── Step 3: Poll for tokens ──────────────────────────────────────────────
              _setPhase(RuntimePhase.waitingFirstToken);
              final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
              final tokenBuf = tokenBufRaw.cast<Utf8>();
              var repeatedTokenCount = 0;
              var consecutiveInvalidTokens = 0;
              String? lastPiece;
              final fullText = StringBuffer();
              final startedAt = DateTime.now();
              var lastTokenProgressAt = startedAt;
              var lastNativeActivityAt = startedAt;
              var consecutiveIdlePolls = 0;
              _updateRuntimeStatus(
                LocalRuntimeStatus.inferencing,
                message: 'Generating',
                tokensGenerated: 0,
                elapsed: Duration.zero,
                startedAt: startedAt,
              );
              _logAi('streaming callback active');
              _log('[STREAM_ADD] event=generation_started session=$sessionId');
              _log('[TOKEN_STREAM] loop start max_tokens=$maxTokens');
              _log('[TOKEN_LOOP] phase=start max_tokens=$maxTokens');
              _log('[FFI_PRE_POLL] session=$sessionId native_session=$nativeSessionId');
              _log('[FFI_POLL_BEGIN] session=$nativeSessionId');
              _preFirstTokenActive = true;
              _setPhase(RuntimePhase.waitingFirstToken);
              var firstPollBoundaryLogged = false;
              var firstPollBoundaryFinished = false;
              _log(
                '[FIRST_TOKEN_POLL_LOOP_BEGIN] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                ' sessionId=$sessionId nativeSessionId=$nativeSessionId phase=$_currentFfiPhase'
                ' pre_first_token_active=true max_tokens=$maxTokens',
              );

              try {
                while (true) {
                  pollIterations++;
                  if (pollIterations % 50 == 0) {
                    await Future<void>.delayed(const Duration(milliseconds: 1));
                  }
                  final now = DateTime.now();
                  final elapsed = now.difference(startedAt);
                  final sinceFirstToken =
                      firstTokenAt == null ? null : now.difference(firstTokenAt);
                  final sinceLastTokenProgress = now.difference(lastTokenProgressAt);
                  _throttledLoopLog(
                    '[TOKEN_STREAM] poll iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}'
                    ' idle_ms=${sinceLastTokenProgress.inMilliseconds} idle_polls=$consecutiveIdlePolls phase=$_currentFfiPhase',
                  );
                  _throttledLoopLog(
                    '[TOKEN_LOOP] iteration=$pollIterations tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',
                  );
                  _throttledLoopLog(
                    '[GENERATION_STEP] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds}'
                    ' generated_tokens=$estimatedTokens',
                  );
                  _throttledLoopLog(
                    '[GENERATION_ALIVE] iteration=$pollIterations elapsed_ms=${elapsed.inMilliseconds} first_token=${firstTokenAt != null}',
                  );
                  if (firstTokenAt == null && pollIterations % 25 == 0) {
                    _log(
                      '[FIRST_TOKEN_WAIT] iteration=$pollIterations waited_ms=${elapsed.inMilliseconds}',
                    );
                  }
                  if (cancellationToken.isCancelled || controller.isClosed) {
                    classifyFirstTokenTermination(
                      reason: 'poll_cancellation',
                      boundary: 'poll_loop',
                      cancellation: true,
                    );
                    _safeCancel(bindings, nativeSessionId);
                    clearRuntimeVerification();
                    _log(
                      '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
                    );
                    if (!controller.isClosed) {
                      _finishWithRuntimeError(
                        controller,
                        stage: 'cancelled',
                        message: 'Inference cancelled.',
                        state: InferenceTerminalState.cancelled,
                      );
                    }
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.runtimeUnavailable,
                      message: 'Cancelled',
                      tokensGenerated: estimatedTokens,
                      elapsed: DateTime.now().difference(startedAt),
                    );
                    _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=pre_poll_cancellation');
                    break;
                  }

                  if (elapsed > _generationTimeout) {
                    classifyFirstTokenTermination(
                      reason: firstTokenAt == null
                          ? 'generation_timeout_no_first_token'
                          : 'generation_timeout',
                      boundary: 'poll_loop',
                      runtimeReset: true,
                    );
                    _setPhase(RuntimePhase.stalled);
                    _log(
                      '[FFI_TIMEOUT] session=$sessionId stage=generation_timeout'
                      ' timeout_ms=${_generationTimeout.inMilliseconds}',
                    );
                    _safeCancel(bindings, nativeSessionId);
                    clearRuntimeVerification();
                    _setPhase(RuntimePhase.failed);
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'generation_timeout';
                    if (firstTokenAt == null) {
                      _log(
                        '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                        ' sessionId=$sessionId reason=generation_timeout_no_first_token'
                        ' elapsed_ms=${elapsed.inMilliseconds}'
                        ' timeout_ms=${_generationTimeout.inMilliseconds}'
                        ' poll_iterations=$pollIterations',
                      );
                    }
                    _log(
                      '[TERMINAL_STATE] state=timedOut reason=generation_timeout'
                      ' generated_tokens=$estimatedTokens elapsed_ms=${elapsed.inMilliseconds}',
                    );
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.timedOut,
                      message: 'Timed out',
                      tokensGenerated: estimatedTokens,
                      elapsed: elapsed,
                      startedAt: startedAt,
                    );
                    _logAi('inference timeout');
                    await _finishWithPartialOrRuntimeError(
                      controller,
                      stage: 'timeout',
                      message: 'Local generation timed out.',
                      modelId: modelId,
                      fullText: fullText.toString(),
                      tokensGenerated: estimatedTokens,
                      notice:
                          'Local model timed out after ${elapsed.inSeconds}s. Returning partial response.',
                      partialTerminalState: InferenceTerminalState.timeout,
                    );
                    break;
                  }
                  final firstTokenWaitElapsed = now.difference(lastNativeActivityAt);
                  if (firstTokenAt == null &&
                      firstTokenWaitElapsed.inMilliseconds >
                          firstTokenDeadline.inMilliseconds) {
                    classifyFirstTokenTermination(
                      reason: 'first_token_watchdog',
                      boundary: 'poll_loop',
                      runtimeReset: true,
                    );
                    _setPhase(RuntimePhase.stalled);
                    _log(
                      '[FFI_TIMEOUT] session=$sessionId stage=first_token_watchdog'
                      ' timeout_ms=${firstTokenDeadline.inMilliseconds}',
                    );
                    _safeCancel(bindings, nativeSessionId);
                    clearRuntimeVerification();
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'first_token_watchdog';
                    _log(
                      '[STREAM_TIMEOUT] reason=no_first_token elapsed_ms=${elapsed.inMilliseconds}'
                      ' timeout_ms=${firstTokenDeadline.inMilliseconds} session=$sessionId',
                    );
                    _log(
                      '[STALL] reason=first_token_watchdog elapsed_ms=${elapsed.inMilliseconds}'
                      ' no_token_produced=true session=$sessionId',
                    );
                    _log(
                      '[FIRST_TOKEN_TIMEOUT] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=$pollIterations timeout_ms=${firstTokenDeadline.inMilliseconds}',
                    );
                    _log(
                      '[FIRST_TOKEN_FAILURE] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                      ' sessionId=$sessionId reason=first_token_watchdog'
                      ' elapsed_ms=${elapsed.inMilliseconds} timeout_ms=${firstTokenDeadline.inMilliseconds}'
                      ' poll_iterations=$pollIterations pre_first_token_active=$_preFirstTokenActive',
                    );
                    _log(
                      '[TERMINAL_STATE] state=stalled reason=first_token_watchdog'
                      ' elapsed_ms=${elapsed.inMilliseconds} no_token_produced=true',
                    );
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.stalled,
                      message: 'Runtime stalled',
                      tokensGenerated: estimatedTokens,
                      elapsed: elapsed,
                      startedAt: startedAt,
                    );
                    _logAi('inference timeout');
                    _finishWithRuntimeError(
                      controller,
                      stage: 'stalled',
                      message: isForensicSelfTest
                          ? 'FIRST_TOKEN_TIMEOUT'
                          : 'Local model stalled during inference.',
                    );
                    break;
                  }
                  if (firstTokenAt != null &&
                      sinceLastTokenProgress > _noTokenProgressTimeout) {
                    classifyFirstTokenTermination(
                      reason: 'token_progress_watchdog',
                      boundary: 'poll_loop',
                      runtimeReset: true,
                    );
                    _setPhase(RuntimePhase.stalled);
                    _safeCancel(bindings, nativeSessionId);
                    clearRuntimeVerification();
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'token_progress_watchdog';
                    _log(
                      '[STALL] reason=token_progress_watchdog'
                      ' generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${elapsed.inMilliseconds}'
                      ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}'
                      ' session=$sessionId',
                    );
                    _log(
                      '[TERMINAL_STATE] state=stalled reason=token_progress_watchdog'
                      ' generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${elapsed.inMilliseconds}'
                      ' since_last_token_ms=${sinceLastTokenProgress.inMilliseconds}',
                    );
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.stalled,
                      message: 'Token stream stalled',
                      tokensGenerated: estimatedTokens,
                      elapsed: elapsed,
                      startedAt: startedAt,
                    );
                    await _finishWithPartialOrRuntimeError(
                      controller,
                      stage: 'stalled',
                      message: 'Token stream stalled during local inference.',
                      modelId: modelId,
                      fullText: fullText.toString(),
                      tokensGenerated: estimatedTokens,
                      notice:
                          'Token stream stalled after ${sinceLastTokenProgress.inSeconds}s. Returning partial response.',
                      partialTerminalState: InferenceTerminalState.timeout,
                    );
                    break;
                  }
                  if (consecutiveIdlePolls >= _maxIdlePollIterations) {
                    classifyFirstTokenTermination(
                      reason: 'poll_loop_watchdog',
                      boundary: 'poll_loop',
                      runtimeReset: true,
                    );
                    _setPhase(RuntimePhase.stalled);
                    _safeCancel(bindings, nativeSessionId);
                    clearRuntimeVerification();
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'poll_loop_watchdog';
                    _log(
                      '[STREAM_TIMEOUT] reason=poll_loop_idle idle_polls=$consecutiveIdlePolls'
                      ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
                    );
                    _log(
                      '[STALL] reason=poll_loop_watchdog'
                      ' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${elapsed.inMilliseconds} session=$sessionId',
                    );
                    _log(
                      '[TERMINAL_STATE] state=stalled reason=poll_loop_watchdog'
                      ' idle_polls=$consecutiveIdlePolls generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${elapsed.inMilliseconds}',
                    );
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.stalled,
                      message: 'Polling loop stalled',
                      tokensGenerated: estimatedTokens,
                      elapsed: elapsed,
                      startedAt: startedAt,
                    );
                    await _finishWithPartialOrRuntimeError(
                      controller,
                      stage: 'poll_loop',
                      message: 'Token polling stalled in local runtime.',
                      modelId: modelId,
                      fullText: fullText.toString(),
                      tokensGenerated: estimatedTokens,
                      notice:
                          'No token progress detected in polling loop. Returning partial response.',
                      partialTerminalState: InferenceTerminalState.timeout,
                    );
                    break;
                  }

                  int status;
                  try {
                    _throttledLoopLog(
                      '[FFI_POLL_BEGIN] entering pollToken session=$nativeSessionId '
                      'iteration=$pollIterations phase=$_currentFfiPhase',
                    );
                    if (!firstPollBoundaryLogged) {
                      firstPollBoundaryLogged = true;
                      final pollHandleHex =
                          '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
                      final pollHandleAddress = nativeSessionId > 0
                          ? Pointer<Void>.fromAddress(nativeSessionId).address
                          : 0;
                      final activeBeforeFirstPoll = bindings.sessionIsActive(nativeSessionId);
                      _log(
                        '[FORENSIC_BEFORE_FIRST_LLB_SESSION_POLL_TOKEN] modelId=$modelId modelPath=$modelPath'
                        ' sessionId=$sessionId nativeSessionId=$nativeSessionId'
                        ' pointer_hex=$pollHandleHex pointer_address=$pollHandleAddress'
                        ' session_active=$activeBeforeFirstPoll isolateHash=${_currentThreadId()}'
                        ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
                        ' token_buffer_pointer_hex=0x${tokenBufRaw.address.toUnsigned(64).toRadixString(16)}'
                        ' token_buffer_pointer_address=${tokenBufRaw.address}',
                      );
                    }
                    _log(
                      '[FFI_CALLBACK_ENTER] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations',
                    );
                    status = bindings.pollToken(nativeSessionId, tokenBuf);
                    if (!firstPollBoundaryFinished) {
                      firstPollBoundaryFinished = true;
                      final pollHandleHex =
                          '0x${nativeSessionId.toUnsigned(64).toRadixString(16)}';
                      final pollHandleAddress = nativeSessionId > 0
                          ? Pointer<Void>.fromAddress(nativeSessionId).address
                          : 0;
                      final activeAfterFirstPoll = bindings.sessionIsActive(nativeSessionId);
                      _log(
                        '[FORENSIC_AFTER_FIRST_LLB_SESSION_POLL_TOKEN] modelId=$modelId modelPath=$modelPath'
                        ' sessionId=$sessionId nativeSessionId=$nativeSessionId status=$status'
                        ' pointer_hex=$pollHandleHex pointer_address=$pollHandleAddress'
                        ' session_active=$activeAfterFirstPoll isolateHash=${_currentThreadId()}'
                        ' thread_id=$dartThreadId session_cache_size=${_nativeSessionsByModel.length}'
                        ' token_buffer_pointer_hex=0x${tokenBufRaw.address.toUnsigned(64).toRadixString(16)}'
                        ' token_buffer_pointer_address=${tokenBufRaw.address}',
                      );
                    }
                  } catch (error) {
                    classifyFirstTokenTermination(
                      reason: 'poll_token_exception',
                      boundary: 'poll_token',
                      exception: true,
                      runtimeReset: true,
                    );
                    clearRuntimeVerification();
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'poll_token_exception';
                    _setPhase(RuntimePhase.failed);
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.failed,
                      message: 'Native poll_token failed: $error',
                    );
                    _finishWithRuntimeError(
                      controller,
                      stage: 'poll_token',
                      message: 'Native poll_token failed.',
                      details: error.toString(),
                    );
                    break;
                  }
                  _throttledLoopLog(
                    '[TOKEN_STREAM] poll status iteration=$pollIterations status=$status',
                  );
                  _log(
                    '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${elapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 poll_iteration=$pollIterations status=$status',
                  );

                  if (status == 1) {
                    String piece;
                    try {
                      piece = tokenBuf.toDartString();
                    } catch (error) {
                      _log('[TOKENIZER_DECODE_FAIL] stage=dart_utf8_decode error=$error');
                      consecutiveInvalidTokens++;
                      if (consecutiveInvalidTokens >= _maxConsecutiveInvalidTokens) {
                        classifyFirstTokenTermination(
                          reason: 'token_decode_exception',
                          boundary: 'token_decode',
                          exception: true,
                          runtimeReset: true,
                        );
                        _safeCancel(bindings, nativeSessionId);
                        clearRuntimeVerification();
                        runtimeNeedsReset = true;
                        runtimeResetReason = 'token_decode_exception';
                        _log(
                          '[TERMINAL_STATE] state=failed reason=token_decode_exception'
                          ' generated_tokens=$estimatedTokens'
                          ' error=$error',
                        );
                        _updateRuntimeStatus(
                          LocalRuntimeStatus.failed,
                          message: 'Invalid generated token stream.',
                          tokensGenerated: estimatedTokens,
                          elapsed: DateTime.now().difference(startedAt),
                          startedAt: startedAt,
                        );
                        _finishWithRuntimeError(
                          controller,
                          stage: 'token_decode',
                          message: 'Invalid generated token stream.',
                          details: error.toString(),
                        );
                        break;
                      }
                      continue;
                    }
                    final trimmedPiece = piece.trim();
                    final tokenObservedAt = DateTime.now();
                    lastNativeActivityAt = tokenObservedAt;
                    if (_shouldIgnoreToken(trimmedPiece)) {
                    continue;
                    }
                    final sanitizedPiece = _sanitizeLlmOutput(piece);
                    final trimmedSanitizedPiece = sanitizedPiece.trim();
                    if (trimmedSanitizedPiece.isEmpty) {
                    continue;
                    }

                    _resetIdleBackoff();
                    final isFirstToken = firstTokenAt == null;
                    DateTime? firstTokenTimestamp;
                    if (isFirstToken && _preFirstTokenActive) {
                    firstTokenTimestamp = _handleFirstTokenIfNeeded(sanitizedPiece);
                    if (firstTokenTimestamp != null) {
                      firstTokenAt = firstTokenTimestamp;
                    }
                    }
                    final firstTokenReceived = firstTokenTimestamp != null;
                    consecutiveInvalidTokens = 0;
                    consecutiveIdlePolls = 0;
                    lastTokenProgressAt = tokenObservedAt;
                    fullText.write(sanitizedPiece);
                    estimatedTokens++;
                    recordVerificationSuccess(
                    modelPath: modelPath,
                    source: 'first_token',
                    );
                    final streamingElapsed = DateTime.now().difference(startedAt);
                    _log(
                    '[FFI_CALLBACK_PAYLOAD] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=$pollIterations status=$status',
                    );
                    _log(
                    '[DART_STREAM_RECEIVE] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',
                    );
                    if (firstTokenReceived) {
                    freePromptNativePtr();
                    _log(
                        '[FFI_FIRST_TOKEN] session=$nativeSessionId elapsed_ms=${streamingElapsed.inMilliseconds} chars=${sanitizedPiece.length} phase=$_runtimePhase',
                    );
                    _log(
                        '[FIRST_TOKEN] elapsed_ms=${streamingElapsed.inMilliseconds}'
                        ' token_text_length=${sanitizedPiece.length}'
                        ' poll_iteration=$pollIterations session=$sessionId',
                    );
                    _log(
                        '[FIRST_TOKEN_REAL] elapsed_ms=${streamingElapsed.inMilliseconds}'
                        ' thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length}'
                        ' queue_size=-1 poll_iteration=$pollIterations'
                        ' token="${sanitizedPiece.replaceAll('\n', r'\n')}" token_count=$estimatedTokens',
                    );
                    _log(
                        '[FIRST_TOKEN_SUCCESS] attemptId=${_currentFirstTokenAttemptId ?? 'unknown'}'
                        ' sessionId=$sessionId nativeSessionId=$nativeSessionId'
                        ' elapsed_ms=${streamingElapsed.inMilliseconds}'
                        ' chars=${sanitizedPiece.length} poll_iterations=$pollIterations'
                        ' pre_first_token_active=false',
                    );
                    }
                    _log(
                    '[DART_TOKEN_RECEIVED] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=$pollIterations',
                    );
                    _log('[FFI_TOKEN] session=$nativeSessionId chars=${sanitizedPiece.length}');
                    if (estimatedTokens % 16 == 0) {
                    _log('[TOKEN_STREAM] token_count=$estimatedTokens');
                    }
                    _log(
                    '[TOKEN_STREAM] piece token_index=$estimatedTokens text="${sanitizedPiece.replaceAll('\n', r'\n')}"'
                    ' total_chars=${fullText.length} since_first_token_ms=${sinceFirstToken?.inMilliseconds ?? 0}',
                    );
                    _log(
                    '[TOKEN_EVAL] token_index=$estimatedTokens elapsed_ms=${streamingElapsed.inMilliseconds}',
                    );
                    _log(
                    '[TOKEN_DECODE] token_index=$estimatedTokens chars=${sanitizedPiece.length}'
                    ' text="${sanitizedPiece.replaceAll('\n', r'\n')}"',
                    );
                    if (sanitizedPiece == lastPiece) {
                    repeatedTokenCount++;
                    if (repeatedTokenCount >= _maxRepeatedTokenLoop) {
                        classifyFirstTokenTermination(
                          reason: 'repeated_token_loop',
                          boundary: 'generation_loop',
                          runtimeReset: true,
                        );
                        _safeCancel(bindings, nativeSessionId);
                        clearRuntimeVerification();
                        runtimeNeedsReset = true;
                        runtimeResetReason = 'repeated_token_loop';
                        _setPhase(RuntimePhase.failed);
                        _log(
                          '[STREAM_LOOP] reason=repeated_token'
                          ' count=$repeatedTokenCount token="${sanitizedPiece.replaceAll('\n', r'\n')}"'
                          ' generated_tokens=$estimatedTokens session=$sessionId',
                        );
                        _log(
                          '[TERMINAL_STATE] state=failed reason=repeated_token_loop'
                          ' generated_tokens=$estimatedTokens'
                          ' elapsed_ms=${streamingElapsed.inMilliseconds}',
                        );
                        _updateRuntimeStatus(
                          LocalRuntimeStatus.failed,
                          message: 'Repeated-token loop detected.',
                          tokensGenerated: estimatedTokens,
                          elapsed: streamingElapsed,
                          startedAt: startedAt,
                        );
                        _finishWithRuntimeError(
                          controller,
                          stage: 'generation_loop',
                          message: 'Repeated-token loop detected.',
                          details: 'token="$sanitizedPiece"',
                        );
                        break;
                    }
                    } else {
                    lastPiece = sanitizedPiece;
                    repeatedTokenCount = 0;
                    }
                    _setPhase(RuntimePhase.streaming);
                    _updateRuntimeStatus(
                    LocalRuntimeStatus.streaming,
                    message: 'Streaming',
                    tokensGenerated: estimatedTokens,
                    elapsed: streamingElapsed,
                    startedAt: startedAt,
                    );
                    _log(
                    '[TOKEN_EMIT] token_index=$estimatedTokens chars=${sanitizedPiece.length}'
                    ' session=$sessionId',
                    );
                    _log(
                    '[DART_STREAM_RENDER] elapsed_ms=${streamingElapsed.inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=${sanitizedPiece.length} queue_size=-1 poll_iteration=$pollIterations subscription_alive=${!controller.isClosed}',
                    );
                    _log('[STREAM_ADD] event=token session=$sessionId');
                    final flushWatch = Stopwatch()..start();
                    try {
                    if (!controller.isClosed) {
                        controller.add(
                          InferenceResponse.token(
                            text: sanitizedPiece,
                            model: modelId,
                          ),
                        );
                        if (firstTokenReceived) {
                          _log('[FORENSIC_FIRST_TOKEN] sessionId=$sessionId nativeSessionId=$nativeSessionId chars=${sanitizedPiece.length}');
                        }
                    }
                    } catch (_) {}
                    flushWatch.stop();
                    _log(
                    '[STREAM_FLUSH] event=token session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}',
                    );
                  } else if (status == 2) {
                    classifyFirstTokenTermination(
                      reason: 'completed',
                      boundary: 'poll_loop',
                    );
                    _setPhase(RuntimePhase.completed);
                    // EOS or max-tokens: generation complete.
                    final completedElapsed = DateTime.now().difference(startedAt);
                    recordVerificationSuccess(
                      modelPath: modelPath,
                      source: 'eos',
                    );
                    _log('[FFI_EOS] session=$nativeSessionId');
                    _log(
                      '[GENERATION_END] state=success generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${completedElapsed.inMilliseconds}',
                    );
                    _log(
                      '[FINAL_RESPONSE] eos generated_tokens=$estimatedTokens elapsed_ms=${completedElapsed.inMilliseconds}',
                    );
                    _log(
                      '[TERMINAL_STATE] state=success generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${completedElapsed.inMilliseconds}',
                    );
                    _logAi('inference completed');
                    _log('[STREAM_ADD] event=final_chunk session=$sessionId');
                    final flushWatch = Stopwatch()..start();
                    if (!controller.isClosed) {
                      final finalText = fullText.toString();
                      controller.add(InferenceResponse.finalChunk(
                        text: finalText.isEmpty ? '\u200B' : finalText,
                        tokensGenerated: estimatedTokens,
                        model: modelId,
                      ));
                    }
                    flushWatch.stop();
                    _log(
                      '[STREAM_FLUSH] event=final_chunk session=$sessionId flush_us=${flushWatch.elapsedMicroseconds}',
                    );
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.completed,
                      message: 'Completed',
                      tokensGenerated: estimatedTokens,
                      elapsed: completedElapsed,
                      startedAt: startedAt,
                    );
                    break;
                  } else if (status == -99) {
                    classifyFirstTokenTermination(
                      reason: 'native_cancelled',
                      boundary: 'poll_loop',
                      cancellation: true,
                    );
                    _setPhase(RuntimePhase.cancelled);
                    _log('[GENERATION_END] state=cancelled generated_tokens=$estimatedTokens');
                    _log(
                      '[TERMINAL_STATE] state=cancelled generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}',
                    );
                    clearRuntimeVerification();
                    if (!controller.isClosed) {
                      _finishWithRuntimeError(
                        controller,
                        stage: 'cancelled',
                        message: 'Inference cancelled.',
                        state: InferenceTerminalState.cancelled,
                      );
                    }
                    _log('[FFI_RUNTIME_UNAVAILABLE_REASON] session=$sessionId reason=native_cancelled');
                    _updateRuntimeStatus(
                      LocalRuntimeStatus.runtimeUnavailable,
                      tokensGenerated: estimatedTokens,
                      elapsed: DateTime.now().difference(startedAt),
                    );
                    break;
                  } else if (status == -1) {
                    classifyFirstTokenTermination(
                      reason: 'native_error',
                      boundary: 'poll_loop',
                      runtimeReset: true,
                    );
                    _setPhase(RuntimePhase.failed);
                    clearRuntimeVerification();
                    final err = _safeLastError(bindings, nativeSessionId);
                    _log('[GENERATION_ERROR] stage=poll_token_native_error error=$err');
                    final statusLower = err.toLowerCase();
                    runtimeNeedsReset = true;
                    runtimeResetReason = 'native_error';
                    _log(
                      '[TERMINAL_STATE] state=native_error generated_tokens=$estimatedTokens'
                      ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}'
                      ' error=$err',
                    );
                    if (statusLower.contains('out of memory') ||
                        statusLower.contains('oom') ||
                        statusLower.contains('memory')) {
                      _updateRuntimeStatus(LocalRuntimeStatus.failed,
                          message: 'Out of memory: $err',
                          tokensGenerated: estimatedTokens,
                          elapsed: DateTime.now().difference(startedAt),
                          startedAt: startedAt);
                    } else {
                      _updateRuntimeStatus(
                        LocalRuntimeStatus.failed,
                        message: err,
                        tokensGenerated: estimatedTokens,
                        elapsed: DateTime.now().difference(startedAt),
                        startedAt: startedAt,
                      );
                    }
                    if ((statusLower.contains('timeout') || statusLower.contains('stalled')) &&
                        fullText.toString().trim().isNotEmpty) {
                      await _finishWithPartialOrRuntimeError(
                        controller,
                        stage: 'generation',
                        message: err.isNotEmpty ? err : 'Inference failed.',
                        modelId: modelId,
                        fullText: fullText.toString(),
                        tokensGenerated: estimatedTokens,
                        notice: err,
                        partialTerminalState: InferenceTerminalState.timeout,
                      );
                    } else {
                      if (!controller.isClosed) {
                        _finishWithRuntimeError(
                          controller,
                          stage: 'generation',
                          message: err.isNotEmpty ? err : 'Inference failed.',
                        );
                      }
                    }
                    break;
                  } else {
                    // status == 0: nessun token pronto; rilasciamo il controllo all'event loop.
                    consecutiveIdlePolls++;
                    if (consecutiveIdlePolls % 120 == 0) {
                      _throttledLoopLog(
                        '[TOKEN_STREAM] idle polling continues: idle_polls=$consecutiveIdlePolls '
                        'idle_ms=${DateTime.now().difference(lastTokenProgressAt).inMilliseconds}',
                      );
                    }
                    
                    // ── CRITICAL FIRST TOKEN FIX: Ottimizzazione della Latenza Iniziale ──────
                    if (_preFirstTokenActive) {
                      // Durante l'ingestion e prima del primo token, usiamo un delay immediato
                      // (Duration.zero) per massimizzare la reattività e non ritardare la UI mobile.
                      await Future<void>.delayed(Duration.zero);
                    } else {
                      // Dopo il primo token, applichiamo il meccanismo di backoff adattivo
                      _increaseIdleBackoff();
                      await Future<void>.delayed(Duration(milliseconds: _idleBackoffMs));
                    }
                    // ─────────────────────────────────────────────────────────────────────────
                  }
                }
              } finally {
                freePromptNativePtr();
                if (runtimeNeedsReset) {
                  _safeResetRuntime(
                    bindings,
                    reason: runtimeResetReason ?? 'runtime_recovery',
                  );
                }
                final terminalState = monitor.state.status;
                _log(
                  '[TERMINAL_STATE] state=${terminalState.name}'
                  ' generated_tokens=$estimatedTokens'
                  ' elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds}'
                  ' first_token=${firstTokenAt != null} ffi_phase=$_currentFfiPhase',
                );
                if (terminalState == LocalRuntimeStatus.loading ||
                    terminalState == LocalRuntimeStatus.tokenizing ||
                    terminalState == LocalRuntimeStatus.inferencing ||
                    terminalState == LocalRuntimeStatus.streaming) {
                  _updateRuntimeStatus(
                    LocalRuntimeStatus.ready,
                    message: 'Runtime verified and ready for the next prompt.',
                    tokensGenerated: 0,
                    elapsed: Duration.zero,
                    startedAt: null,
                    resetProgress: true,
                  );
                }
                calloc.free(tokenBufRaw);
                
                // ── Gestione Centralizzata e Sicura di Chiusura dello Stream ───────────
                if (!controller.isClosed) {
                  _log('[FFI_STREAM_CLOSE] session=$sessionId reason=stream_finally_close');
                  _log(
                    '[DART_STREAM_CLOSE] elapsed_ms=${DateTime.now().difference(startedAt).inMilliseconds} thread_id=$dartThreadId token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=$pollIterations session=$sessionId',
                  );
                  try {
                    await controller.close();
                  } catch (_) {}
                }
                // ───────────────────────────────────────────────────────────────────────
              }
            } catch (error, stackTrace) {
              classifyFirstTokenTermination(
                reason: firstFfiInvocationAttempted
                    ? 'stream_inference_unhandled_post_ffi'
                    : 'stream_inference_unhandled_pre_ffi',
                boundary: 'stream_inference',
                cancellation: cancellationToken.isCancelled,
                exception: true,
              );
              _log('[FFI_EXCEPTION] session=$sessionId stage=stream_inference_unhandled error=$error');
              _log('[FFI_EXCEPTION] session=$sessionId stack=$stackTrace');
              if (!firstFfiInvocationAttempted) {
                await fatalEarlyExit(
                  sessionId,
                  branch: 'stream_inference_unhandled_pre_ffi',
                  reason: 'Unhandled exception before first FFI call: $error',
                  stage: 'stream_inference',
                  details: '$stackTrace',
                );
              } else if (!controller.isClosed) {
                _finishWithRuntimeError(
                  controller,
                  stage: 'stream_inference',
                  message: 'Unhandled runtime exception.',
                  details: '$error',
                );
              }
            } finally {
              finalizeFirstTokenAttempt();
              _log(
                '[FFI_FLOW_EXIT] session=$sessionId first_ffi_attempted=$firstFfiInvocationAttempted'
                ' first_ffi_completed=$firstFfiInvocationCompleted controller_closed=${controller.isClosed}',
              );
              if (!firstFfiInvocationAttempted) {
                _log(
                  '[PRE_FFI_ISOLATE_FAILURE_ASSERT] session=$sessionId first_ffi_attempted=false fatal=true',
                );
              }
              if (!isVerificationSession) {
                _releaseInferenceSlot(sessionId);
              }
              _log('[SESSION] end session=$sessionId');
            }
          });
          _log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1655 | Function: streamInference() | AFTER calling _runInferenceSerially()',
          );
        } catch (e, stackTrace) {
          _log(
            '[AI_RUNTIME_MONITOR] FORENSIC_EXCEPTION - File: android_ffi_runtime_provider.dart | Line: 1659 | Function: streamInference() | BEFORE rethrow after async execution exception: $e \n $stackTrace',
          );
          rethrow;
        }
      }, (error, stack) {
        _log('[ASYNC_CLOSURE_ZONE_UNCAUGHT] sessionId=${request.sessionId} modelId=${request.modelId} error=$error stack=$stack');
      });

      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1666 | Function: streamInference() | AFTER exit',
      );
      return controller.stream;
    } catch (e, stackTrace) {
      _log(
        '[FORENSIC_UNHANDLED_EXCEPTION] error=$e stackTrace=$stackTrace',
      );
      rethrow;
    }
  }

  TokenStream streamVerificationInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1683 | Function: streamVerificationInference() | BEFORE entry',
      );
      final controller = StreamController<InferenceResponse>();
      () async {
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1688 | Function: streamVerificationInference() | BEFORE calling _runInferenceSerially()',
        );
        try {
          await _runInferenceSerially(() async {
            _log(
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1693 | Function: streamVerificationInference() | BEFORE calling _runInVerificationScope()',
            );
            final verificationRawModelPath = request.modelPath;
            final verificationModelPath =
                verificationRawModelPath == null ||
                        verificationRawModelPath.trim().isEmpty
                    ? verificationRawModelPath
                    : await _resolveHybridModelPath(verificationRawModelPath);
            await _runInVerificationScope(
              modelPath: verificationModelPath,
              action: () async {
                final modelPath = verificationModelPath;
                final modelId = request.modelId;
                if (modelPath == null ||
                    modelPath.trim().isEmpty ||
                    modelId == null ||
                    modelId.trim().isEmpty) {
                  _finishWithRuntimeError(
                    controller,
                    stage: 'verification_request_validation',
                    message: 'Missing local model path.',
                  );
                  verificationMonitor.update(
                    RuntimeVerificationPhase.failed,
                    message: 'Verification request missing model metadata.',
                  );
                  return;
                }
                if (!_ensureLibraryLoaded()) {
                  _finishWithRuntimeError(
                    controller,
                    stage: 'verification_library_load',
                    message: 'Local AI runtime library (libllama_bridge.so) not found.',
                  );
                  verificationMonitor.update(
                    RuntimeVerificationPhase.failed,
                    message: 'libllama_bridge.so missing for current build.',
                  );
                  return;
                }
                final bindings = _bindings!;
                verificationMonitor.update(
                  RuntimeVerificationPhase.loading,
                  message: 'Creating isolated verification session.',
                );
                final verificationSessionId = bindings.createSession(modelPath);
                if (verificationSessionId <= 0) {
                  final err = _safeLastError(bindings, verificationSessionId);
                  _finishWithRuntimeError(
                    controller,
                    stage: 'verification_session_create',
                    message: 'Verification session create failed.',
                    details: err,
                  );
                  verificationMonitor.update(
                    RuntimeVerificationPhase.failed,
                    message: 'Verification session create failed: $err',
                  );
                  clearRuntimeVerification();
                  return;
                }
                final tokenBufRaw = calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);
                final tokenBuf = tokenBufRaw.cast<Utf8>();
                var emittedTokens = 0;
                final fullText = StringBuffer();
                var released = false;
                
                final verificationPromptPtr =
                    request.prompt.toNativeUtf8(allocator: calloc);
                Pointer<Utf8>? verificationPromptPtrOrNull = verificationPromptPtr;
                void freeVerificationPromptPtr() {
                  final ptr = verificationPromptPtrOrNull;
                  if (ptr != null) {
                    calloc.free(ptr);
                    verificationPromptPtrOrNull = null;
                  }
                }
                try {
                  final startResult = bindings.startGeneration(
                    verificationSessionId,
                    verificationPromptPtr,
                    request.maxTokens.clamp(1, _safeMaxTokens),
                    request.temperature,
                  );
                  if (startResult != 0) {
                    freeVerificationPromptPtr();
                    final err = _safeLastError(bindings, verificationSessionId);
                    _finishWithRuntimeError(
                      controller,
                      stage: 'verification_start_generation',
                      message: 'Failed to start isolated runtime verification.',
                      details: err,
                    );
                    verificationMonitor.update(
                      RuntimeVerificationPhase.failed,
                      message: 'Verification start_generation failed: $err',
                    );
                    clearRuntimeVerification();
                    return;
                  }
                  verificationMonitor.update(
                    RuntimeVerificationPhase.running,
                    message: 'Verification inference running.',
                  );
                  final startedAt = DateTime.now();
                  var verificationFirstTokenReceived = false;
                  while (true) {
                    if (cancellationToken.isCancelled || controller.isClosed) {
                      freeVerificationPromptPtr();
                      _safeCancel(bindings, verificationSessionId);
                      if (!controller.isClosed) {
                        _finishWithRuntimeError(
                          controller,
                          stage: 'verification_cancelled',
                          message: 'Verification cancelled.',
                          state: InferenceTerminalState.cancelled,
                        );
                      }
                      verificationMonitor.update(
                        RuntimeVerificationPhase.failed,
                        message: 'Verification cancelled.',
                      );
                      return;
                    }
                    final elapsed = DateTime.now().difference(startedAt);
                    if (elapsed > _generationTimeout) {
                      freeVerificationPromptPtr();
                      _setPhase(RuntimePhase.stalled);
                      _safeCancel(bindings, verificationSessionId);
                      _finishWithRuntimeError(
                        controller,
                        stage: 'verification_timeout',
                        message: 'Runtime verification timed out.',
                        state: InferenceTerminalState.timeout,
                      );
                      verificationMonitor.update(
                        RuntimeVerificationPhase.failed,
                        message: 'Runtime verification timed out.',
                      );
                      clearRuntimeVerification();
                      return;
                    }
                    _log(
                      '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1813 | Function: streamVerificationInference() | BEFORE verification pollToken loop iteration',
                    );
                    final status = bindings.pollToken(verificationSessionId, tokenBuf);
                    _log(
                      '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1817 | Function: streamVerificationInference() | AFTER verification pollToken loop iteration status=$status',
                    );
                    if (status == 1) {
                      final piece = tokenBuf.toDartString();
                      final trimmedPiece = piece.trim();
                      if (_shouldIgnoreToken(trimmedPiece)) {
                        continue;
                      }
                      final sanitizedPiece = _sanitizeLlmOutput(piece);
                      if (sanitizedPiece.trim().isEmpty) {
                        continue;
                      }

                      if (!verificationFirstTokenReceived) {
                        freeVerificationPromptPtr();
                        verificationFirstTokenReceived = true;
                        _setPhase(RuntimePhase.streaming);
                      }
                      emittedTokens++;
                      fullText.write(sanitizedPiece);
                      if (!controller.isClosed) {
                        controller.add(
                          InferenceResponse.token(
                            text: sanitizedPiece,
                            model: modelId,
                          ),
                        );
                      }
                      continue;
                    }
                    if (status == 2) {
                      freeVerificationPromptPtr();
                      _setPhase(RuntimePhase.completed);
                      break;
                    }
                    if (status == -1) {
                      freeVerificationPromptPtr();
                      _setPhase(RuntimePhase.failed);
                      final err = _safeLastError(bindings, verificationSessionId);
                      _finishWithRuntimeError(
                        controller,
                        stage: 'verification_poll_token',
                        message: 'Verification poll_token failed.',
                        details: err,
                      );
                      verificationMonitor.update(
                        RuntimeVerificationPhase.failed,
                        message: 'Verification poll_token failed: $err',
                      );
                      clearRuntimeVerification();
                      return;
                    }
                    if (status == -99) {
                      freeVerificationPromptPtr();
                      _setPhase(RuntimePhase.cancelled);
                      _finishWithRuntimeError(
                        controller,
                        stage: 'verification_cancelled_native',
                        message: 'Verification cancelled by native runtime.',
                        state: InferenceTerminalState.cancelled,
                      );
                      verificationMonitor.update(
                        RuntimeVerificationPhase.failed,
                        message: 'Verification cancelled by native runtime.',
                      );
                      return;
                    }
                    await Future<void>.delayed(const Duration(milliseconds: 24));
                  }

                  recordVerificationSuccess(
                    modelPath: modelPath,
                    source: 'verification_scope',
                  );
                  verificationMonitor.update(
                    RuntimeVerificationPhase.passed,
                    message: 'Runtime verification passed.',
                  );
                  if (!controller.isClosed) {
                    final finalText = fullText.toString();
                    controller.add(
                      InferenceResponse.finalChunk(
                        text: finalText.isEmpty ? '\u200B' : finalText,
                        tokensGenerated: emittedTokens,
                        model: modelId,
                      ),
                    );
                    await controller.close();
                  }
                } finally {
                  freeVerificationPromptPtr();
                  calloc.free(tokenBufRaw);
                  _safeCancel(bindings, verificationSessionId);
                  try {
                    bindings.releaseSession(verificationSessionId);
                    released = true;
                  } catch (error) {
                    _log(
                      '[VERIFICATION_UI_IGNORED] verification_scope=true reason=verification_release_exception error=$error',
                    );
                  }
                }
              },
            );
            _log(
              '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1922 | Function: streamVerificationInference() | AFTER calling _runInVerificationScope()',
            );
          });
          _log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1926 | Function: streamVerificationInference() | AFTER calling _runInferenceSerially()',
          );
        } catch (e, stackTrace) {
          rethrow;
        }
      }();
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 1936 | Function: streamVerificationInference() | AFTER exit',
      );
      return controller.stream;
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  int _ensureNativeSession(
    LlamaBridgeBindings bindings,
    String modelPath, {
    String? modelId,
  }) =>
      _nativeSessionSubsystem.ensureNativeSession(
        bindings,
        modelPath,
        modelId: modelId,
      );

  void _releaseNativeSessionByModelPath(
    LlamaBridgeBindings bindings,
    String modelPath, {
    required String reason,
  }) => _nativeSessionSubsystem.releaseNativeSessionByModelPath(
        bindings,
        modelPath,
        reason: reason,
      );

  void _evictLeastRecentlyUsedSessionIfNeeded(LlamaBridgeBindings bindings) =>
      _nativeSessionSubsystem.evictLeastRecentlyUsedSessionIfNeeded(bindings);

  void _markSessionAsMostRecentlyUsed(String modelPath) =>
      _nativeSessionSubsystem.markSessionAsMostRecentlyUsed(modelPath);

  void _releaseAllNativeSessions(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) => _nativeSessionSubsystem.releaseAllNativeSessions(
        bindings,
        reason: reason,
      );

  Future<void> _runInferenceSerially(Future<void> Function() action) {
    try {
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2030 | Function: _runInferenceSerially() | BEFORE entry',
      );
      _log('[SERIAL_QUEUE_SCHEDULE] tail_hash=${_inferenceTail.hashCode} schedule_ts=${DateTime.now().microsecondsSinceEpoch} isolateHash=${_currentThreadId()}');
      final next = _inferenceTail.then((_) async {
        _log('[SERIAL_QUEUE_DEQUEUE] dequeue_ts=${DateTime.now().microsecondsSinceEpoch} isolateHash=${_currentThreadId()}');
        _log(
          '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2034 | Function: _runInferenceSerially() | BEFORE action()',
        );
        try {
          await action();
          _log(
            '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2039 | Function: _runInferenceSerially() | AFTER action()',
          );
        } catch (e, st) {
          _log('[SERIAL_QUEUE_ERROR] $e $st');
          rethrow;
        }
      });
      _inferenceTail = next.catchError((_) {});
      _log(
        '[AI_RUNTIME_MONITOR] FORENSIC - File: android_ffi_runtime_provider.dart | Line: 2051 | Function: _runInferenceSerially() | AFTER exit',
      );
      return next;
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  void _traceFfiPhase(FfiPhase phase) {
    _log('[FFI_PHASE_TRANSITION] phase=${phase.name} ts=${DateTime.now().microsecondsSinceEpoch}');
  }

  void _setPhase(RuntimePhase phase) {
    if (_runtimePhase == phase) {
      return;
    }
    _runtimePhase = phase;
    switch (phase) {
      case RuntimePhase.tokenizing:
        _currentFfiPhase = FfiPhase.sessionCreating;
        break;
      case RuntimePhase.startingGeneration:
        _currentFfiPhase = FfiPhase.generationStarting;
        break;
      case RuntimePhase.waitingFirstToken:
        _currentFfiPhase = FfiPhase.promptIngestion;
        break;
      case RuntimePhase.streaming:
        _currentFfiPhase = FfiPhase.streamingTokens;
        break;
      case RuntimePhase.completed:
      case RuntimePhase.failed:
      case RuntimePhase.cancelled:
      case RuntimePhase.stalled:
        _currentFfiPhase = FfiPhase.terminating;
        break;
    }
    _log(
      '[RUNTIME_PHASE_TRANSITION] phase=${phase.name} ffi_phase=${_currentFfiPhase.name} ts=${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  String _sanitizeLlmOutput(String input) {
    var output = input;
    for (final token in _systemSanityTags) {
      output = output.replaceAll(token, '');
    }
    return output;
  }

  bool _isNoiseToken(String piece) {
    return piece.isEmpty || _systemSanityTags.contains(piece);
  }

  bool _shouldIgnoreToken(String piece) {
    // Keep the raw noise predicate separate so future ignore heuristics can
    // expand without reworking the sanitization path.
    return _isNoiseToken(piece);
  }

  DateTime? _handleFirstTokenIfNeeded(String piece) {
    if (!_preFirstTokenActive) {
      return null;
    }
    _preFirstTokenActive = false;
    _setPhase(RuntimePhase.streaming);
    final now = DateTime.now();
    _log(
      '[FIRST_TOKEN_PHASE] phase=${_runtimePhase.name} chars=${piece.length} ts=${now.microsecondsSinceEpoch}',
    );
    return now;
  }

  void _throttledLoopLog(String message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLoopLogAtMs >= _loopLogThrottleMs) {
      _lastLoopLogAtMs = now;
      _log(message);
    }
  }

  void _increaseIdleBackoff() {
    _idleBackoffMs = (_idleBackoffMs * 2).clamp(24, 200);
  }

  void _resetIdleBackoff() {
    _idleBackoffMs = 24;
  }

  Future<T> _runNativeCallWithTimeout<T>({
    required String stage,
    required Duration timeout,
    required T Function() call,
  }) =>
      _warmupSubsystem.runNativeCallWithTimeout(
        stage: stage,
        timeout: timeout,
        call: call,
      );

  bool _claimInferenceSlot(String sessionId) {
    if (_activeInferenceSessions.contains(sessionId)) return false;
    _activeInferenceSessions.add(sessionId);
    return true;
  }

  void _releaseInferenceSlot(String sessionId) {
    _activeInferenceSessions.remove(sessionId);
  }

  /// Returns true when warmup succeeds.
  Future<bool> _ensureWarmup({
    required String sessionId,
    required String modelPath,
  }) =>
      _warmupSubsystem.ensureWarmup(
        sessionId: sessionId,
        modelPath: modelPath,
      );

  Future<void> _runWarmup({required String modelPath}) =>
      _warmupSubsystem.runWarmup(modelPath: modelPath);

  static void _finishWithError(
    StreamController<InferenceResponse> ctrl,
    String message, {
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    if (ctrl.isClosed) return;
    ctrl.add(InferenceResponse.error(message, state: state));
    _log('[FFI_STREAM_CLOSE] reason=finish_with_error');
    _log(
      '[DART_STREAM_CLOSE] elapsed_ms=0 thread_id=${_currentThreadId()} token_id=-1 token_text_length=0 queue_size=-1 poll_iteration=-1 reason=finish_with_error',
    );
    ctrl.close();
  }

  static void _finishWithRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    String? details,
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) {
    final exception = RuntimeStageException(
      stage: stage,
      message: message,
      details: details,
    );
    final payload = exception.toPayload();
    _log('[GENERATION_ERROR] stage=$stage message=$message details=${details ?? ''}');
    _logAi(
      'runtime error: ${exception.toLogMessage()}',
    );
    _log(payload);
    _finishWithError(ctrl, payload, state: state);
  }

  static Future<void> _finishWithPartialOrRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    required String modelId,
    required String fullText,
    required int tokensGenerated,
    String? notice,
    InferenceTerminalState partialTerminalState = InferenceTerminalState.failed,
  }) async {
    if (ctrl.isClosed) return;
    if (fullText.trim().isNotEmpty) {
      if (notice != null && notice.trim().isNotEmpty) {
        _log('[STREAM_ADD] event=notice');
        ctrl.add(InferenceResponse.notice(notice));
      }
      _log('[STREAM_ADD] event=final_partial');
      ctrl.add(
        InferenceResponse(
          text: fullText,
          model: modelId,
          tokensGenerated: tokensGenerated,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isFinal: true,
          terminalState: partialTerminalState,
        ),
      );
      _log('[FFI_STREAM_CLOSE] reason=partial_or_runtime_error');
      if (!ctrl.isClosed) {
        try {
          await ctrl.close();
        } catch (_) {}
      }
      return;
    }
    _finishWithRuntimeError(
      ctrl,
      stage: stage,
      message: message,
      state: partialTerminalState,
    );
  }

  String _composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
  }) {
    if (bypassNonessentialLayers) {
      _log(
        '[FORENSIC_BYPASS] session=${request.sessionId} mode=raw_prompt_only semantic_memory=false embeddings=false workspace_indexing=false retrieval_augmentation=false conversation_rebuild=false',
      );
      return request.prompt.trim();
    }
    return LocalPromptTemplates.compose(
      modelId: modelId,
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  static String? _validateModelFileForRuntime(String modelPath) {
    final file = File(modelPath);
    if (!file.existsSync()) {
      return 'Selected model file does not exist.';
    }
    if (!modelPath.toLowerCase().endsWith('.gguf')) {
      return 'Selected model is not a GGUF file.';
    }
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.read);
      final length = handle.lengthSync();
      if (length <= _minValidModelSizeBytes) {
        return 'Selected model appears truncated or corrupted.';
      }
      final header = handle.readSync(4);
      if (header.length < 4 ||
          header[0] != 0x47 ||
          header[1] != 0x47 ||
          header[2] != 0x55 ||
          header[3] != 0x46) {
        return 'Selected model has an invalid GGUF header.';
      }
      return null;
    } catch (_) {
      return 'Selected model file is not readable.';
    } finally {
      handle?.closeSync();
    }
  }

  static String _safeLastError(LlamaBridgeBindings bindings, int sessionId) {
    try {
      final value = bindings.sessionLastError(sessionId);
      if (value.trim().isEmpty) return 'Unknown native runtime error.';
      _log('[MODEL_EXECUTION] native error: $value');
      return value;
    } catch (error) {
      _log('[MODEL_EXECUTION] llb_session_last_error failed: $error');
      return 'Native runtime error (unable to read details).';
    }
  }

  void _safeCancel(LlamaBridgeBindings bindings, int sessionId) =>
      _nativeSessionSubsystem.safeCancel(bindings, sessionId);

  void _safeResetRuntime(
    LlamaBridgeBindings bindings, {
    required String reason,
  }) =>
      _nativeSessionSubsystem.safeResetRuntime(
        bindings,
        reason: reason,
      );

  static void _log(String message) {
    RuntimeEventLog.instance.emit(message);
    if (message.contains('FORENSIC_')) return;
    _printCounter++;
    if (_printCounter % 10 == 0) {
      final safeMessage =
          message.length > 220 ? message.substring(0, 220) : message;
      debugPrint('[$_logTag] $safeMessage');
    }
  }

  static void _logAi(String message) {
    debugPrint('[AI] $message');
  }

  static int _currentThreadId() => Isolate.current.hashCode;

  @override
  @protected
  void clearRuntimeVerification() {
    if (_inVerificationScope) {
      _log(
        '[VERIFICATION_UI_IGNORED] verification_scope=true reason=clear_runtime_verification_ignored',
      );
      return;
    }
    final caller = kDebugMode
        ? _inferCallerFromStack()
        : 'AndroidFfiRuntimeProvider.clearRuntimeVerification';
    _emitStateReset(
      reason: 'verification_invalidated',
      origin: caller,
    );
    _verifiedRuntimeAbi = null;
    super.clearRuntimeVerification();
  }

  void _updateRuntimeStatus(
    LocalRuntimeStatus status, {
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
    bool resetProgress = false,
    String reason = _autoTransitionReason,
    String origin = 'AndroidFfiRuntimeProvider',
  }) => _lifecycleSubsystem.updateRuntimeStatus(
        status,
        message: message,
        tokensGenerated: tokensGenerated,
        elapsed: elapsed,
        startedAt: startedAt,
        resetProgress: resetProgress,
        reason: reason,
        origin: origin,
      );

  void _syncLifecycleState(
    LocalRuntimeStatus status, {
    required String reason,
    required String origin,
  }) =>
      _lifecycleSubsystem.syncLifecycleState(
        status,
        reason: reason,
        origin: origin,
      );

  @override
  void recordVerificationSuccess({
    required String modelPath,
    String source = 'runtime',
  }) {
    super.recordVerificationSuccess(modelPath: modelPath, source: source);
    _verifiedRuntimeAbi = LlamaFfiLoader.currentAbiName;
    _manualVerificationResetRequested = false;
    if (_inVerificationScope) {
      _log(
        '[VERIFICATION_UI_IGNORED] verification_scope=true reason=record_verification_success_skip_ui_transition source=$source',
      );
      return;
    }
    final status = monitor.state.status;
    if (status == LocalRuntimeStatus.runtimeUnavailable ||
        status == LocalRuntimeStatus.uninitialized) {
      _updateRuntimeStatus(
        LocalRuntimeStatus.ready,
        message: 'Runtime verified and ready for inference.',
      );
    } else if (status == LocalRuntimeStatus.failed ||
        status == LocalRuntimeStatus.completed) {
      _updateRuntimeStatus(
        LocalRuntimeStatus.ready,
        message: 'Runtime re-verified and ready for inference.',
      );
    } else {
      runtimeStateMachine.markVerified();
    }
  }

  String _defaultReasonFor(LocalRuntimeStatus status) =>
      _lifecycleSubsystem.defaultReasonFor(status);

  String _expectedNextFor(LocalRuntimeStatus status) =>
      _lifecycleSubsystem.expectedNextFor(status);

  void _traceStatePath({
    required LocalRuntimeStatus from,
    required LocalRuntimeStatus to,
    required String reason,
    required String origin,
  }) =>
      _lifecycleSubsystem.traceStatePath(
        from: from,
        to: to,
        reason: reason,
        origin: origin,
      );

  void _emitStateReset({
    required String reason,
    required String origin,
  }) =>
      _lifecycleSubsystem.emitStateReset(
        reason: reason,
        origin: origin,
      );

  String _inferCallerFromStack() => _lifecycleSubsystem.inferCallerFromStack();

  Future<String> _resolveHybridModelPath(String rawModelPath) async {
    final trimmedPath = rawModelPath.trim();
    final fileName = p.basename(trimmedPath);
    final resolution = await _pathResolver.resolveForRead(
      fileName: fileName,
      privateAbsolutePathHint: trimmedPath,
    );
    return resolution.file.path;
  }

  String _normalizePathForLogs(String modelPath) {
    final trimmed = modelPath.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      return File(trimmed).absolute.path;
    } catch (_) {
      return trimmed;
    }
  }
}
