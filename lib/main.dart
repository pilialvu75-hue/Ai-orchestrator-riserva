import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:ai_orchestrator/app/app_shell.dart';
import 'package:ai_orchestrator/app/runtime_bootstrap.dart';
import 'package:ai_orchestrator/app/splash_screen.dart';
import 'package:ai_orchestrator/app/startup_transition_controller.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/language_service.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_bloc.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StartupApp());
}

class StartupApp extends StatefulWidget {
  const StartupApp({super.key});

  @override
  State<StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<StartupApp> {
  final StartupTransitionController _transitionController =
      StartupTransitionController();
  final RuntimeBootstrap _bootstrap = const RuntimeBootstrap();

  Object? _startupError;

  @override
  void initState() {
    super.initState();
    _startBootstrap();
  }

  Future<void> _startBootstrap() async {
    try {
      await _bootstrap.initialize();
      if (!mounted) return;
      _transitionController.markReady();
      setState(() {
        _startupError = null;
      });
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
            home: const AppShell(),
          );
        },
      ),
    );
  }
}
