import 'dart:io';
import 'package:ai_orchestrator/core/runtime/inference/completion_output.dart';

import 'package:path/path.dart' as path;

/// Windows' bundled, CPU-only completion process. No shell or user PATH needed.
abstract final class WindowsLlamaRuntime {
  static String resolveExecutable({
    required String appExecutable,
    required Map<String, String> environment,
    String windowsVersion = '',
    bool Function(String)? fileExists,
  }) {
    final modern = path.windows.join(path.windows.dirname(appExecutable),
        'runtime-modern', 'llama-completion.exe');
    final exists = fileExists ?? (String value) => File(value).existsSync();
    // The modern upstream package selects CPU variants at runtime, but needs
    // Windows 10+. Never load its DLLs on the legacy Windows route.
    if (isModernWindows(windowsVersion) && exists(modern)) return modern;
    final bundled = path.windows.join(
      path.windows.dirname(appExecutable),
      'llama-completion.exe',
    );
    // Prefer the shipped helper over stale machine-specific workarounds.
    if ((fileExists ?? (value) => File(value).existsSync())(bundled)) {
      return bundled;
    }
    final override = environment['LLAMA_CPP_EXECUTABLE']?.trim();
    return override != null && override.isNotEmpty ? override : 'llama-cli';
  }

  static bool isModernWindows(String version) => RegExp(
        r'(?:\bWindows\s+(?:10|11)\b|\b10\.0\b)',
        caseSensitive: false,
      ).hasMatch(version);

  static List<String> arguments({required int processors}) => <String>[
        '--no-conversation',
        '--simple-io',
        '--color',
        'off',
        '--verbosity',
        '0',
        // Avoid allocating the model's potentially very large training context.
        '-c',
        '4096',
        '-t',
        (processors ~/ 2).clamp(1, 8).toString(),
        '-ngl',
        '0',
      ];

  /// Keep the terminal sentinel out of the response, even across pipe chunks.
  static Stream<String> visibleOutput(Stream<String> chunks) =>
      CompletionOutput.visible(chunks);
}
