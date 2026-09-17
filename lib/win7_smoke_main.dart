import 'package:flutter/material.dart';

// Deliberately tiny entrypoint: no AI, storage, voice, updater, or app bootstrap.
// A successful first frame here proves the Flutter/Win7 engine path itself.
void main() {
  runApp(const Win7SmokeApp());
}

class Win7SmokeApp extends StatelessWidget {
  const Win7SmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Orchestrator Win7 Smoke',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.check_circle_outline, size: 72),
                SizedBox(height: 20),
                Text(
                  'AI Orchestrator\nWindows 7 Flutter smoke test\nUI OK',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
