import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WorkshopWebApp());
}

class WorkshopWebApp extends StatelessWidget {
  const WorkshopWebApp({super.key});

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
      home: const WorkshopWebShell(),
    );
  }
}
