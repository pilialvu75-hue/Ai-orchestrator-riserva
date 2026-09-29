import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_checkpoint_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    WorkshopWebApp(
      checkpointStore: WorkshopWebCheckpointStorage.open(),
    ),
  );
}

class WorkshopWebApp extends StatelessWidget {
  const WorkshopWebApp({
    super.key,
    required this.checkpointStore,
  });

  final Future<WorkshopCheckpointStore> checkpointStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI-Orchestrator Cantiere Web',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8AB4F8),
          secondary: Color(0xFF6ECBF5),
          surface: Color(0xFF171717),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: WorkshopWebShell(
        checkpointStore: checkpointStore,
      ),
    );
  }
}
