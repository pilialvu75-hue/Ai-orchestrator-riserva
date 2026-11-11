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
    final exists = fileExists ?? (String value) => File(value).existsSync();
    final bundled = path.windows.join(
      path.windows.dirname(appExecutable),
      'llama-completion.exe',
    );
    final modern = path.windows.join(path.windows.dirname(appExecutable),
        'runtime-modern', 'llama-completion.exe');

    // Production installs ship the statically linked helper. Older installers
    // could leave runtime-modern behind, and its unsigned DLLs may be rejected
    // by Windows Smart App Control. Never select it merely because it exists.
    // Explicit Windows QA can opt into the DLL runtime without changing the
    // production default.
    if (modernRuntimeEnabled(
          windowsVersion: windowsVersion,
          environment: environment,
        ) &&
        exists(modern)) {
      return modern;
    }
    if (exists(bundled)) return bundled;
    final override = environment['LLAMA_CPP_EXECUTABLE']?.trim();
    return override != null && override.isNotEmpty ? override : 'llama-cli';
  }

  static bool modernRuntimeEnabled({
    required String windowsVersion,
    required Map<String, String> environment,
  }) =>
      isModernWindows(windowsVersion) &&
      environment['AI_ORCHESTRATOR_WINDOWS_MODERN_RUNTIME'] == '1';

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
