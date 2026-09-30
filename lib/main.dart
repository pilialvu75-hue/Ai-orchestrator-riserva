import 'package:ai_orchestrator/core/diagnostics/github_diagnostics.dart';
import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui';

import 'package:ai_orchestrator/core/runtime/inference/android_process_exit_diagnostics.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:ai_orchestrator/app/app_shell_router.dart';
import 'package:ai_orchestrator/app/runtime_bootstrap.dart';
import 'package:ai_orchestrator/app/splash_screen.dart';
import 'package:ai_orchestrator/app/startup_transition_controller.dart';
import 'package:ai_orchestrator/core/app_legal/app_legal_initializer.dart';
import 'package:ai_orchestrator/core/app_health/contracts/abstract_telemetry_service.dart';
import 'package:ai_orchestrator/core/app_legal/services/eula_service.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/language_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_bloc.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

/// Emits a [FORENSIC_UNCAUGHT_DART_EXCEPTION] entry through the shared
/// RuntimeEventLog pipeline and prints to the debug console.
///
/// This is intentionally a top-level function so it can be reached from
/// every exception handler (zone, FlutterError, PlatformDispatcher, isolate)
/// without capturing mutable state.
void _emitForensicException(
  Object error,
  StackTrace stackTrace, {
  required String source,
}) {
  final timestamp = DateTime.now().toIso8601String();
  final message =
      '[FORENSIC_UNCAUGHT_DART_EXCEPTION] '
      'timestamp=$timestamp '
      'source=$source '
      'type=${error.runtimeType} '
      'message=$error\n'
      'stack=\n$stackTrace';
  debugPrint(message);
  RuntimeEventLog.instance.emit(message);

  // The telemetry backend is registered during RuntimeBootstrap. Before that
  // point the existing local forensic log remains the source of truth.
  if (di.sl.isRegistered<AbstractTelemetryService>()) {
    di.sl<AbstractTelemetryService>().logCrash(
      error,
      stackTrace: stackTrace,
      context: source,
    );
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final deferWindowsStartup =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final windows7UiSmokeOnly = args.contains('--windows7-ui-smoke-only');
  if (windows7UiSmokeOnly) {
    _appendWindowsDartStartupBreadcrumb('D00 main entered smoke-only mode');
  }

  // Preserve the established startup order everywhere except Windows. On
  // Windows the first frame is allowed to render before disk/plugin/service
  // initialization so legacy hosts cannot fail before showing any UI.
  if (!deferWindowsStartup) {
    await RuntimeEventLog.instance.initPersistence();
    unawaited(recordAndroidProcessExitHistory());
    unawaited(GitHubDiagnostics.instance.initialize());
  }

  // ── Global exception handlers ─────────────────────────────────────────────
  // All three handlers capture exceptions into RuntimeEventLog so that
  // Runtime Diagnostics shows [FORENSIC_UNCAUGHT_DART_EXCEPTION] entries
  // when the crash originates inside Dart.  None of them rethrow or terminate
  // the application; the UI is kept alive to distinguish a Dart exception
  // (Scenario A) from a native process termination (Scenario B).

  FlutterError.onError = (FlutterErrorDetails details) {
    _emitForensicException(
      details.exception,
      details.stack ?? StackTrace.empty,
      source: 'FlutterError',
    );
    // presentError shows a non-fatal diagnostic widget in debug builds;
    // it is a no-op in release builds and does not terminate the process.
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    _emitForensicException(error, stackTrace, source: 'PlatformDispatcher');
    // Return true to mark the error as handled and suppress platform
    // propagation that would otherwise terminate the application.
    return true;
  };

  final isolateErrorPort = RawReceivePort((dynamic pair) {
    if (pair is List<dynamic> && pair.length >= 2) {
      _emitForensicException(
        pair[0] as Object? ?? 'unknown',
        StackTrace.fromString('${pair[1]}'),
        source: 'isolate',
      );
      return;
    }
    _emitForensicException(
      pair as Object? ?? 'unknown',
      StackTrace.empty,
      source: 'isolate',
    );
  });
  Isolate.current.addErrorListener(isolateErrorPort.sendPort);

  // Confirm that all handlers are active before the app tree is built.
  RuntimeEventLog.instance
      .emit('[FORENSIC_GLOBAL_EXCEPTION_HANDLERS_INSTALLED]');

  await runZonedGuarded(
    () async {
      runApp(
        StartupApp(
          deferWindowsStartup: deferWindowsStartup,
          windows7UiSmokeOnly: windows7UiSmokeOnly,
        ),
      );
    },
    (Object error, StackTrace stackTrace) {
      _emitForensicException(error, stackTrace, source: 'runZonedGuarded');
    },
  );
}

class StartupApp extends StatefulWidget {
  const StartupApp({
    super.key,
    required this.deferWindowsStartup,
    required this.windows7UiSmokeOnly,
  });

  final bool deferWindowsStartup;
  final bool windows7UiSmokeOnly;

  @override
  State<StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<StartupApp> {
  final StartupTransitionController _transitionController =
      StartupTransitionController();
  final RuntimeBootstrap _bootstrap = const RuntimeBootstrap();

  Object? _startupError;
  bool _diagnosticsInitialized = false;

  @override
  void initState() {
    super.initState();
    if (widget.windows7UiSmokeOnly) {
      _appendWindowsDartStartupBreadcrumb('D10 StartupApp initState smoke-only');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _appendWindowsDartStartupBreadcrumb(
          'D20 Dart post-frame callback reached smoke-only',
        );
      });
      return;
    }
    if (widget.deferWindowsStartup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_startBootstrap());
        }
      });
    } else {
      unawaited(_startBootstrap());
    }
  }

  Future<void> _initializeDeferredDiagnostics() async {
    if (!widget.deferWindowsStartup || _diagnosticsInitialized) return;
    _diagnosticsInitialized = true;

    try {
      await RuntimeEventLog.instance.initPersistence();
    } catch (error, stackTrace) {
      _emitForensicException(
        error,
        stackTrace,
        source: 'RuntimeEventLog.initPersistence',
      );
    }

    unawaited(recordAndroidProcessExitHistory());
    unawaited(GitHubDiagnostics.instance.initialize());
    RuntimeEventLog.instance.emit('[WINDOWS_SAFE_STARTUP_FIRST_FRAME_REACHED]');
  }

  Future<void> _startBootstrap() async {
    try {
      await _initializeDeferredDiagnostics();
      await _bootstrap.initialize();
      if (!mounted) return;
      _transitionController.markReady();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _startupError = error;
      });
    }
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.windows7UiSmokeOnly) {
      _appendWindowsDartStartupBreadcrumb('D15 smoke-only widget build');
      return const _Windows7UiSmokeScreen();
    }

    return AnimatedBuilder(
      animation: _transitionController,
      builder: (context, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _transitionController.isReady
              ? const AppRoot(key: ValueKey('ready'))
              : MaterialApp(
                  key: const ValueKey('startup'),
                  debugShowCheckedModeBanner: false,
                  themeMode: ThemeMode.dark,
                  darkTheme: ThemeData.dark(useMaterial3: true),
                  home: _startupError == null
                      ? const SplashScreen()
                      : _StartupErrorScreen(
                          error: _startupError!,
                          onRetry: () {
                            setState(() {
                              _startupError = null;
                            });
                            _startBootstrap();
                          },
                        ),
                ),
        );
      },
    );
  }
}

void _appendWindowsDartStartupBreadcrumb(String message) {
  try {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return;
    final directory =
        Directory('$localAppData\\AI-Orchestrator\\Diagnostics');
    directory.createSync(recursive: true);
    final file = File(
      '${directory.path}\\AI-Orchestrator-dart-startup.log',
    );
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\r\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

class _Windows7UiSmokeScreen extends StatelessWidget {
  const _Windows7UiSmokeScreen();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF203050),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: Color(0xFF75D68A), size: 52),
              SizedBox(height: 16),
              Text(
                'AI Orchestrator',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Windows 7 Flutter UI smoke test',
                style: TextStyle(color: Color(0xFFD0DBEE), fontSize: 14),
              ),
              SizedBox(height: 6),
              Text(
                'Bootstrap intentionally disabled',
                style: TextStyle(color: Color(0xFF9EB4D2), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFFFB74D),
                size: 36,
              ),
              const SizedBox(height: 12),
              const Text(
                'Startup failed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final languageService = di.sl<LanguageService>();
    return MultiBlocProvider(
      providers: [
        BlocProvider<OrchestratorStateEngine>(
            create: (_) => di.sl<OrchestratorStateEngine>()),
        BlocProvider<ProjectMemoryBloc>(
            create: (_) => di.sl<ProjectMemoryBloc>()),
        BlocProvider<ModelDownloadBloc>(
            create: (_) => di.sl<ModelDownloadBloc>()
              ..add(const LoadAvailableModels())),
      ],
      child: ListenableBuilder(
        listenable: languageService,
        builder: (context, _) {
          return MaterialApp(
            title: 'AI Orchestrator',
            debugShowCheckedModeBanner: false,
            locale: languageService.currentLocale,
            supportedLocales: languageService.config.supportedLanguages,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            themeMode: ThemeMode.dark,
            theme: ThemeData(
              colorScheme:
                  ColorScheme.fromSeed(seedColor: const Color(0xFF8AB4F8)),
              useMaterial3: true,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              colorScheme: const ColorScheme.dark(
                primary: Color(0xFF8AB4F8),
                secondary: Color(0xFF6ECBF5),
                surface: Color(0xFF1A1A1A),
                onSurface: Colors.white,
              ),
              scaffoldBackgroundColor: const Color(0xFF0D0D0D),
            ),
            home: AppLegalInitializer(
              eulaService: di.sl<EulaService>(),
              child: const AppShellRouter(),
            ),
          );
        },
      ),
    );
  }
}
