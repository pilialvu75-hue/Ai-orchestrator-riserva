import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

// =============================================================================
// IMPORT DEI TUOI MODELLI E SERVIZI ESTERNI
// Lascia intatti i tuoi import originali qui sotto (es. per InferenceResponse, ecc.)
// =============================================================================
// import 'package:tuo_progetto/...'; 

// =============================================================================
// DIRETTIVE PART CON PERCORSI DISTRIBUITI (4 in src/ e 3 nella radice)
// =============================================================================
// File posizionati nella sottocartella "src/"
part 'src/concurrency_manager.part.dart';
part 'src/execution_boundary.part.dart';
part 'src/session_state_isolator.part.dart';
part 'src/token_stream_processor.part.dart';

// File posizionati nella stessa cartella di questo file principale
part 'lifecycle_subsystem.part.dart';
part 'native_session_subsystem.part.dart';
part 'warmup_subsystem.part.dart';

class AndroidFfiRuntimeProvider {
  AndroidFfiRuntimeProvider() {
    // Inizializzazione dei sottosistemi a istanza
    _concurrency = _AndroidFfiConcurrencyManager(this);
    _lifecycle = _AndroidFfiLifecycleSubsystem(this);
    _nativeSession = _AndroidFfiNativeSessionSubsystem(this);
    _warmup = _AndroidFfiWarmupSubsystem(this);
    _tokenProcessor = _AndroidFfiTokenStreamProcessor(this);
    _sessionIsolator = _AndroidFfiSessionStateIsolator();
    
    // NOTA: _AndroidFfiRuntimeExecutionBoundary non viene inizializzato 
    // perché contiene solo metodi statici.
  }

  // =============================================================================
  // ISTANZE DEI SOTTOSISTEMI (ACCESSIBILI INTERNAMENTE)
  // =============================================================================
  late final _AndroidFfiConcurrencyManager _concurrency;
  late final _AndroidFfiLifecycleSubsystem _lifecycle;
  late final _AndroidFfiNativeSessionSubsystem _nativeSession;
  late final _AndroidFfiWarmupSubsystem _warmup;
  late final _AndroidFfiTokenStreamProcessor _tokenProcessor;
  late final _AndroidFfiSessionStateIsolator _sessionIsolator;

  // =============================================================================
  // COSTANTI RICHIESTE DAI SOTTOSISTEMI (DOVREBBERO COINCIDERE CON LE TUE)
  // =============================================================================
  static const String _autoTransitionReason = 'auto_transition';
  static const int _loopLogThrottleMs = 1000;
  static const int _clearVerificationCallerFrameIndex = 2;
  static const Duration _reentryWarnThreshold = Duration(milliseconds: 1500);
  static const int _reentryLoopBlockThreshold = 5;
  static const Duration _verificationFirstTokenTimeout = Duration(seconds: 15);
  
  static const String _warmupPrompt = '<s>'; 
  static const int _warmupMaxTokens = 4;
  static const double _warmupTemperature = 0.0;
  static const List<String> _systemSanityTags = <String>['[DONE]', '[ERROR]'];

  // =============================================================================
  // STATO INTERNO DELLA MEMORIA E DEL RUNTIME (STATO CONDIVISO)
  // =============================================================================
  // Monitor e macchine a stati (Assicurati che i tuoi tipi combacino)
  final DynamicRuntimeMonitor monitor = DynamicRuntimeMonitor();
  final RuntimeStateMachine runtimeStateMachine = RuntimeStateMachine();
  final VerificationMonitor verificationMonitor = VerificationMonitor();

  // Gestione concorrenza e code FFI
  Future<void>? _inferenceTail;
  final Set<String> _activeInferenceSessions = <String>{};
  final Map<String, int> _nativeSessionsByModel = <String, int>{};
  int? _nativeSessionId;
  final int _maxActiveNativeSessions = 3; 
  
  // Flag di controllo di fase e flussi
  RuntimePhase _runtimePhase = RuntimePhase.uninitialized;
  bool _inVerificationScope = false;
  bool _preFirstTokenActive = false;
  bool _streamInferenceEntered = false;
  int _lastLoopLogAtMs = 0;
  int _idleBackoffMs = 24;

  // Telemetria e tracciamento dei crash/reentry loop
  DateTime? _lastTransitionAt;
  int _transitionCounter = 0;
  int _activeTransitionId = 0;
  String _lastTransitionReason = 'none';
  String _lastTransitionOrigin = 'system';
  int _reentryCount = 0;

  // Binding della libreria nativa C++
  LlamaBridgeBindings? _bindings;
  Future<void>? _warmupFuture;
  String? _warmupModelPath;

  // =============================================================================
  // GETTER E METODI DI INTERFACCIA INTERNA
  // =============================================================================
  RuntimePhase get runtimePhase => _runtimePhase;

  void _setPhase(RuntimePhase phase) {
    _runtimePhase = phase;
  }

  /// Invocato internamente dal Warmup Subsystem per aggiornare lo stato del ciclo di vita
  void _updateRuntimeStatus(
    LocalRuntimeStatus status, {
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
    bool resetProgress = false,
    String reason = _autoTransitionReason,
    String origin = 'provider_core',
  }) {
    _lifecycle.updateRuntimeStatus(
      status,
      message: message,
      tokensGenerated: tokensGenerated,
      elapsed: elapsed,
      startedAt: startedAt,
      resetProgress: resetProgress,
      reason: reason,
      origin: origin,
    );
  }

  /// Invocato dal Warmup Subsystem per agganciare le sessioni attive stabili
  int _ensureNativeSession(LlamaBridgeBindings bindings, String modelPath, {String? modelId}) {
    return _nativeSession.ensureNativeSession(bindings, modelPath, modelId: modelId);
  }

  // =============================================================================
  // STRUTTURE METODI LOG E UTILITY (CHIAMATI DA TUTTI I FILE PART)
  // =============================================================================
  static int _currentThreadId() {
    return Zone.current.hashCode; // Identificativo software del thread/isolate corrente
  }

  static String _safeLastError(LlamaBridgeBindings bindings, int sessionId) {
    try {
      // Modifica qui se hai un metodo sui tuoi bindings per estrarre l'ultimo errore nativo
      return 'FFI execution error context code for session $sessionId';
    } catch (_) {
      return 'Unknown native runtime layer failure';
    }
  }

  static void _log(String message) {
    print(message); // Sostituisci liberamente col tuo Logger di produzione (es. Talker, Flog)
  }

  static void _logAi(String message) {
    print('[AI_ENGINE] $message');
  }

  // =============================================================================
  // CONSERVA QUI SOTTO TUTTO IL TUO VECCHIO CODICE ORIGINALE (~2000+ RIGHE)
  // Incolla qui sotto i tuoi metodi nativi di caricamento libreria (.so),
  // i metodi di avvio dell'Isolate Dart, il caricamento dei file del modello, ecc.
  // Es: _ensureLibraryLoaded(), shouldReuseRuntimeVerification(), ecc.
  // =============================================================================
  
  bool _ensureLibraryLoaded() {
    if (_bindings != null) return true;
    // ... La tua logica nativa originale di caricamento DynamicLibrary.open ...
    return _bindings != null;
  }

  bool shouldReuseRuntimeVerification({required String modelPath}) {
    // ... La tua logica originale per riutilizzare la verifica ...
    return _warmupModelPath == modelPath && _nativeSessionsByModel.containsKey(modelPath);
  }

  void clearRuntimeVerification() {
    _warmupFuture = null;
    _warmupModelPath = null;
  }
}
