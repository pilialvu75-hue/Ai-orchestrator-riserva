import 'dart:async';

/// Target supportati dal Workshop Build Lab.
///
/// Il target descrive ciò che vogliamo costruire, non necessariamente
/// dove la build verrà eseguita.
///
/// Esempio:
///   BuildTarget.windows
///
/// può essere costruito:
///   - localmente, se esiste una toolchain Windows compatibile;
///   - tramite un builder remoto, in futuro.
///
/// macOS/iOS richiedono normalmente un ambiente Apple/macOS.
enum WorkshopBuildTarget {
  android,
  windows,
  linux,
  macos,
  ios,
  web,
}

/// Modalità con cui il laboratorio tenta di costruire il progetto.
enum WorkshopBuildExecutionMode {
  offlineLocal,
  local,
  remote,
  automatic,
}

/// Stato della toolchain richiesta.
enum WorkshopToolchainStatus {
  unknown,
  available,
  unavailable,
  incomplete,
  invalid,
}

/// Stato della build.
enum WorkshopBuildStatus {
  queued,
  preparing,
  running,
  testing,
  succeeded,
  failed,
  cancelled,
}

/// Informazioni sulla toolchain disponibile per un target.
final class WorkshopToolchainInfo {
  const WorkshopToolchainInfo({
    required this.target,
    required this.status,
    required this.executionMode,
    this.name,
    this.version,
    this.path,
    this.missingComponents = const <String>[],
    this.message,
  });

  final WorkshopBuildTarget target;
  final WorkshopToolchainStatus status;
  final WorkshopBuildExecutionMode executionMode;

  final String? name;
  final String? version;
  final String? path;

  final List<String> missingComponents;
  final String? message;

  bool get isAvailable =>
      status == WorkshopToolchainStatus.available;

  bool get canBuildOffline =>
      isAvailable &&
      executionMode ==
          WorkshopBuildExecutionMode.offlineLocal;
}

/// Richiesta di build.
///
/// È indipendente dalla UI e dal motore di build concreto.
final class WorkshopBuildRequest {
  const WorkshopBuildRequest({
    required this.id,
    required this.projectId,
    required this.projectPath,
    required this.target,
    this.mode = WorkshopBuildExecutionMode.automatic,
    this.runTests = true,
    this.runAnalyzer = true,
    this.runFormatter = true,
    this.cleanBuild = false,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
  });

  final String id;
  final String projectId;
  final String projectPath;
  final WorkshopBuildTarget target;

  final WorkshopBuildExecutionMode mode;

  final bool runTests;
  final bool runAnalyzer;
  final bool runFormatter;
  final bool cleanBuild;

  final List<String> arguments;
  final Map<String, String> environment;
}

/// Risultato di una build.
final class WorkshopBuildResult {
  const WorkshopBuildResult({
    required this.requestId,
    required this.target,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.artifactPath,
    this.message,
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.testsPassed,
    this.analysisPassed,
    this.formatPassed,
    this.warnings = const <String>[],
    this.errors = const <String>[],
  });

  final String requestId;
  final WorkshopBuildTarget target;
  final WorkshopBuildStatus status;

  final DateTime startedAt;
  final DateTime finishedAt;

  final String? artifactPath;
  final String? message;

  final String stdout;
  final String stderr;

  final int? exitCode;

  final bool? testsPassed;
  final bool? analysisPassed;
  final bool? formatPassed;

  final List<String> warnings;
  final List<String> errors;

  bool get succeeded =>
      status == WorkshopBuildStatus.succeeded;

  bool get hasArtifact =>
      artifactPath != null &&
      artifactPath!.trim().isNotEmpty;

  Duration get duration =>
      finishedAt.difference(startedAt);
}

/// Evento prodotto dal Build Lab.
final class WorkshopBuildEvent {
  const WorkshopBuildEvent({
    required this.requestId,
    required this.target,
    required this.status,
    required this.timestamp,
    this.message,
    this.progress,
  });

  final String requestId;
  final WorkshopBuildTarget target;
  final WorkshopBuildStatus status;
  final DateTime timestamp;

  final String? message;
  final double? progress;
}

/// Provider di toolchain.
///
/// Ogni ambiente concreto implementerà questa interfaccia.
///
/// In futuro avremo, ad esempio:
///
/// Android:
///   AndroidLocalToolchainProvider
///
/// Linux:
///   LinuxLocalToolchainProvider
///
/// Windows:
///   WindowsRemoteToolchainProvider
///
/// macOS/iOS:
///   MacOSRemoteToolchainProvider
abstract interface class WorkshopBuildProvider {
  WorkshopBuildExecutionMode get executionMode;

  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  );

  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  );

  Future<void> cancel(
    String requestId,
  );
}

/// Provider iniziale che non esegue build.
///
/// È intenzionale: il Build Lab può essere integrato nel progetto
/// senza fingere che una toolchain locale esista già.
///
/// Il provider reale verrà aggiunto in un passaggio successivo.
final class UnavailableWorkshopBuildProvider
    implements WorkshopBuildProvider {
  const UnavailableWorkshopBuildProvider({
    this.mode = WorkshopBuildExecutionMode.offlineLocal,
  });

  final WorkshopBuildExecutionMode mode;

  @override
  WorkshopBuildExecutionMode get executionMode => mode;
  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    return WorkshopToolchainInfo(
      target: target,
      status: WorkshopToolchainStatus.unavailable,
      executionMode: executionMode,
      message:
          'No build provider is currently connected for ${target.name}.',
    );
  }

  @override
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    final now = DateTime.now();

    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: now,
      finishedAt: now,
      message:
          'No build provider is available for ${request.target.name}.',
      errors: <String>[
        'build_provider_unavailable',
      ],
    );
  }

  @override
  Future<void> cancel(
    String requestId,
  ) async {}
}

/// Build Lab del Cantiere.
///
/// Responsabilità:
///
/// - scegliere il provider appropriato;
/// - verificare la toolchain;
/// - avviare una build;
/// - pubblicare gli stati;
/// - mantenere separata la build dalla UI;
/// - permettere in futuro provider locali e remoti.
///
/// NON contiene:
/// - logica LLM;
/// - logica di pianificazione;
/// - logica di applicazione delle modifiche;
/// - logica della Chat Assistente.
///
/// Il Build Lab riceve un progetto già preparato e si occupa solamente
/// della fase build/test/validation.
final class WorkshopBuildLab {
  WorkshopBuildLab({
    Iterable<WorkshopBuildProvider> providers = const <WorkshopBuildProvider>[],
  }) : _providers = List.unmodifiable(
          providers.isEmpty
              ? <WorkshopBuildProvider>[
                  const UnavailableWorkshopBuildProvider(),
                ]
              : providers,
        );

  final List<WorkshopBuildProvider> _providers;

  final StreamController<WorkshopBuildEvent> _events =
      StreamController<WorkshopBuildEvent>.broadcast();

  final Map<String, WorkshopBuildRequest> _activeRequests =
      <String, WorkshopBuildRequest>{};

  bool _disposed = false;

  Stream<WorkshopBuildEvent> get events =>
      _events.stream;

  List<WorkshopBuildRequest> get activeRequests =>
      List.unmodifiable(_activeRequests.values);

  /// Verifica quale provider può gestire il target.
  Future<WorkshopToolchainInfo> inspect(
    WorkshopBuildTarget target, {
    WorkshopBuildExecutionMode mode =
        WorkshopBuildExecutionMode.automatic,
  }) async {
    _ensureAvailable();

    final candidates = _providers.where(
      (provider) =>
          _modeMatches(
            provider.executionMode,
            mode,
          ),
    );

    WorkshopToolchainInfo? firstResult;

    for (final provider in candidates) {
      final info =
          await provider.inspectToolchain(target);

      firstResult ??= info;

      if (info.isAvailable) {
        return info;
      }
    }

    return firstResult ??
        WorkshopToolchainInfo(
          target: target,
          status: WorkshopToolchainStatus.unavailable,
          executionMode: mode,
          message:
              'No provider matches the requested build mode.',
        );
  }

  /// Esegue una build.
  ///
  /// Il Build Lab non decide se applicare il risultato al repository.
  /// Produce solamente un artifact e un risultato di validazione.
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    _ensureAvailable();

    _activeRequests[request.id] = request;

    final provider =
        await _selectProvider(request);

    if (provider == null) {
      final now = DateTime.now();

      final result = WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.failed,
        startedAt: now,
        finishedAt: now,
        message:
            'No compatible build provider is available.',
        errors: <String>[
          'no_compatible_build_provider',
        ],
      );

      _emit(
        request,
        WorkshopBuildStatus.failed,
        result.message,
      );

      _activeRequests.remove(request.id);

      return result;
    }

    _emit(
      request,
      WorkshopBuildStatus.preparing,
      'Preparing ${request.target.name} build.',
    );

    try {
      final result = await provider.build(request);

      _emit(
        request,
        result.status,
        result.message,
      );

      return result;
    } finally {
      _activeRequests.remove(request.id);
    }
  }

  /// Cancella una build attiva.
  Future<void> cancel(
    String requestId,
  ) async {
    _ensureAvailable();

    final request = _activeRequests[requestId];

    if (request == null) {
      return;
    }

    for (final provider in _providers) {
      try {
        await provider.cancel(requestId);
      } catch (_) {
        // Un provider che non riesce a cancellare non deve impedire
        // agli altri provider di ricevere la richiesta.
      }
    }

    _emit(
      request,
      WorkshopBuildStatus.cancelled,
      'Build cancelled.',
    );

    _activeRequests.remove(requestId);
  }

  Future<WorkshopBuildProvider?> _selectProvider(
    WorkshopBuildRequest request,
  ) async {
    for (final provider in _providers) {
      if (!_modeMatches(
        provider.executionMode,
        request.mode,
      )) {
        continue;
      }

      final info = await provider.inspectToolchain(
        request.target,
      );

      if (info.isAvailable) {
        return provider;
      }
    }

    return null;
  }

  bool _modeMatches(
    WorkshopBuildExecutionMode providerMode,
    WorkshopBuildExecutionMode requestedMode,
  ) {
    if (requestedMode ==
        WorkshopBuildExecutionMode.automatic) {
      return true;
    }

    return providerMode == requestedMode;
  }

  void _emit(
    WorkshopBuildRequest request,
    WorkshopBuildStatus status,
    String? message,
  ) {
    if (_events.isClosed) {
      return;
    }

    _events.add(
      WorkshopBuildEvent(
        requestId: request.id,
        target: request.target,
        status: status,
        timestamp: DateTime.now(),
        message: message,
      ),
    );
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopBuildLab has been disposed.',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    await _events.close();
  }
}
