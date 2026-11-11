import 'dart:ffi';
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
    bool avx2Available = false,
  }) {
    final exists = fileExists ?? (String value) => File(value).existsSync();
    final bundled = path.windows.join(
      path.windows.dirname(appExecutable),
      'llama-completion.exe',
    );
    final modern = path.windows.join(path.windows.dirname(appExecutable),
        'runtime-modern', 'llama-completion.exe');
    final avx2 = path.windows.join(path.windows.dirname(appExecutable),
        'runtime-cpu-avx2', 'llama-completion.exe');

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
    if (avx2Available && exists(avx2)) return avx2;
    if (exists(bundled)) return bundled;
    final override = environment['LLAMA_CPP_EXECUTABLE']?.trim();
    return override != null && override.isNotEmpty ? override : 'llama-cli';
  }

  /// Reports AVX2 only when the Windows kernel says the processor and OS
  /// context support it. Any lookup failure retains the portable baseline.
  static bool supportsAvx2() {
    if (!Platform.isWindows) return false;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final isProcessorFeaturePresent = kernel32.lookupFunction<
          Int32 Function(Uint32),
          int Function(int)>('IsProcessorFeaturePresent');
      // PF_AVX2_INSTRUCTIONS_AVAILABLE
      return isProcessorFeaturePresent(40) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Selects only runtimes compatible with the Windows generation. Production
  /// prefers the static Vulkan server; the DLL-based server remains explicit QA.
  static String? resolveResidentServer({
    required String appExecutable,
    required Map<String, String> environment,
    required String windowsVersion,
    bool Function(String)? fileExists,
  }) {
    if (!isModernWindows(windowsVersion)) return null;
    final exists = fileExists ?? (String value) => File(value).existsSync();
    final appDir = path.windows.dirname(appExecutable);
    final modern = path.windows.join(appDir, 'runtime-modern', 'llama-server.exe');
    final vulkan = path.windows.join(appDir, 'runtime-vulkan', 'llama-server.exe');
    if (modernRuntimeEnabled(windowsVersion: windowsVersion, environment: environment) &&
        exists(modern)) {
      return modern;
    }
    return exists(vulkan) ? vulkan : null;
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
