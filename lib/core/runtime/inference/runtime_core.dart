/// Core implementation for the Android FFI runtime provider.
///
/// This library keeps the original runtime behavior intact while delegating
/// token processing, polling control, FFI stream boundaries, and event models
/// to dedicated modules.
library runtime_core;

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
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_models.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

part 'android/lifecycle/android_ffi_runtime_provider_lifecycle_subsystem.part.dart';
part 'android/sessions/android_ffi_runtime_provider_native_session_subsystem.part.dart';
part 'android/warmup/android_ffi_runtime_provider_warmup_subsystem.part.dart';
part 'android/helpers/android_ffi_runtime_provider_concurrency_manager.part.dart';
part 'android/streaming/android_ffi_runtime_provider_token_stream_processor.part.dart';
part 'android/helpers/android_ffi_runtime_provider_session_state_isolator.part.dart';
part 'android/logging/android_ffi_runtime_provider_logging.part.dart';
part 'android/logging/android_ffi_runtime_provider_ffi_bridge_handler.part.dart';
part 'android/polling/android_ffi_runtime_provider_polling_controller.part.dart';
part 'android/diagnostics/android_ffi_runtime_provider_diagnostics.part.dart';
part 'android/streaming/android_ffi_runtime_provider_streaming.part.dart';
part 'android/streaming/android_ffi_runtime_provider_generation_startup.part.dart';
part 'android/streaming/android_ffi_runtime_provider_first_token.part.dart';
part 'android/streaming/android_ffi_runtime_provider_polling.part.dart';
part 'android/streaming/android_ffi_runtime_provider_terminal_state.part.dart';
part 'android/streaming/android_ffi_runtime_provider_stream_verification.part.dart';

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
  // Sanity Layer: Tag speciali e di sistema da rilevare e sopprimere all'istante
  static const Set<String> _systemSanityTags = <String>{
    '<|im_start|>',
    '<|im_end|>',
    '&lt;|im_start|&gt;',
    '&lt;|im_end|&gt;',
    '&amp;lt;|im_start|&gt;',
    '&amp;lt;|im_end|&gt;',
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
  Future<void>? _inferenceTail;
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
  late final _AndroidFfiConcurrencyManager _concurrencyManager =
      _AndroidFfiConcurrencyManager(this);
  late final _AndroidFfiTokenStreamProcessor _tokenStreamProcessor =
      _AndroidFfiTokenStreamProcessor(this);
  late final _AndroidFfiSessionStateIsolator _sessionStateIsolator =
      _AndroidFfiSessionStateIsolator();
  late final _AndroidFfiRuntimePollingController _pollingController =
      _AndroidFfiRuntimePollingController(this);

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

  String _sanitizeStructuralTemplateOutput(String input) =>
      _tokenStreamProcessor.sanitizeStructuralTemplateOutput(input);

  String _flushStructuralTemplateOutput(StringBuffer fullText) =>
      fullText.toString() + _tokenStreamProcessor.flushStructuralTemplateOutput();

  void _discardStructuralTemplateOutput() =>
      _tokenStreamProcessor.discardStructuralTemplateOutput();

  bool _shouldIgnoreToken(String piece) =>
      _tokenStreamProcessor.isNoiseToken(piece);

  DateTime? _handleFirstTokenIfNeeded(String piece) =>
      _tokenStreamProcessor.handleFirstTokenIfNeeded(piece);

  void _throttledLoopLog(String message) {
    _pollingController.throttledLoopLog(message);
  }

  void _increaseIdleBackoff() => _pollingController.increaseIdleBackoff();

  void _resetIdleBackoff() => _pollingController.resetIdleBackoff();

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

  bool _claimInferenceSlot(String sessionId) =>
      _concurrencyManager.claimInferenceSlot(sessionId);

  void _releaseInferenceSlot(String sessionId) =>
      _concurrencyManager.releaseInferenceSlot(sessionId);

  /// Returns true when warmup succeeds.
  Future<bool> _ensureWarmup({
    required String sessionId,
    required String modelPath,
  }) =>
      _warmupSubsystem.ensureWarmup(
        sessionId: sessionId,
        modelPath: modelPath,
      );

  

  static void _finishWithRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    String? details,
    InferenceTerminalState state = InferenceTerminalState.failed,
  }) =>
      _AndroidFfiRuntimeExecutionBoundary.finishWithRuntimeError(
        ctrl,
        stage: stage,
        message: message,
        details: details,
        state: state,
      );

  static Future<void> _finishWithPartialOrRuntimeError(
    StreamController<InferenceResponse> ctrl, {
    required String stage,
    required String message,
    required String modelId,
    required String fullText,
    required int tokensGenerated,
    String? notice,
    InferenceTerminalState partialTerminalState = InferenceTerminalState.failed,
  }) =>
      _AndroidFfiRuntimeExecutionBoundary.finishWithPartialOrRuntimeError(
        ctrl,
        stage: stage,
        message: message,
        modelId: modelId,
        fullText: fullText,
        tokensGenerated: tokensGenerated,
        notice: notice,
        partialTerminalState: partialTerminalState,
      );

  String _composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
  }) =>
      _sessionStateIsolator.composePrompt(
        request,
        modelId: modelId,
        bypassNonessentialLayers: bypassNonessentialLayers,
      );

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
    _AndroidFfiRuntimeLoggingService.log(message);
  }

  static void _logAi(String message) {
    _AndroidFfiRuntimeLoggingService.logAi(message);
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
