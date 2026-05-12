import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:ai_orchestrator/app/splash_screen.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/language_service.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_bloc.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read the real installed version from the platform — never hardcode this.
  const String versionFallback = '1.0.12';
  String appVersion;
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = info.version.isNotEmpty ? info.version : versionFallback;
    debugPrint('[OTA] PackageInfo version: ${info.version}+${info.buildNumber}');
  } catch (e) {
    // Fallback: try compile-time define, then hard default.
    appVersion = const String.fromEnvironment(
      'APP_VERSION',
      defaultValue: versionFallback,
    );
    debugPrint('[OTA] PackageInfo failed ($e), using fallback: $appVersion');
  }

  await di.initDependencies(
    openAiApiKey: const String.fromEnvironment('OPENAI_API_KEY'),
    geminiApiKey: const String.fromEnvironment('GEMINI_API_KEY'),
    claudeApiKey: const String.fromEnvironment('CLAUDE_API_KEY'),
    grokApiKey: const String.fromEnvironment('GROK_API_KEY'),
    copilotApiKey: const String.fromEnvironment('COPILOT_API_KEY'),
    appVersion: appVersion,
  );

  runApp(const AppRoot());
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
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}
