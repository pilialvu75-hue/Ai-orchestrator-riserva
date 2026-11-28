import 'dart:io';
import 'package:ai_orchestrator/core/runtime/inference/completion_output.dart';

import 'package:path/path.dart' as path;

/// Windows' bundled, CPU-only completion process. No shell or user PATH needed.
abstract final class WindowsLlamaRuntime {
  static String resolveExecutable({
    required String appExecutable,
    required Map<String, String> environment,
    String? modelId,
    String windowsVersion = '',
    bool Function(String)? fileExists,
  }) {
    final modern = path.windows.join(path.windows.dirname(appExecutable),
        'runtime-modern', 'llama-completion.exe');
    final exists = fileExists ?? (String value) => File(value).existsSync();
    // An old runtime-modern directory may survive an app update. Its DLLs
    // can be blocked by Windows Code Integrity even when the main executable
    // exists. Never auto-select it: keep the bundled standalone helper as the
    // production default, without deleting any previous installation files.
    //
    // MiniCPM5 requires the newer tokenizer unavailable in the pinned
    // legacy/Win8.1 helper. Route only this explicit Windows 10/11 candidate
    // to the separately bundled, verified modern runtime. Do not silently
    // fall back to legacy if the modern helper is missing: inference must fail
    // clearly rather than produce misleading text.
    final miniCpm5 = (modelId ?? '').toLowerCase().contains('minicpm5');
    if (miniCpm5 && isModernWindows(windowsVersion)) return modern;

    // Explicit QA may opt in on Windows 10/11; Windows 8.1 and earlier must
    // never load the modern runtime, even with this environment override.
    final explicitModernQa =
        isModernWindows(windowsVersion) &&
        environment['AI_ORCHESTRATOR_WINDOWS_MODERN_RUNTIME'] == '1';
    if (explicitModernQa && exists(modern)) return modern;
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
