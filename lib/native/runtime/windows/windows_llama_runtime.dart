import 'dart:io';

import 'package:path/path.dart' as path;

/// Windows' bundled, CPU-only completion process. No shell or user PATH needed.
abstract final class WindowsLlamaRuntime {
  static String resolveExecutable({
    required String appExecutable,
    required Map<String, String> environment,
    bool Function(String)? fileExists,
  }) {
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
  static Stream<String> visibleOutput(Stream<String> chunks) async* {
    const retained = 18;
    var pending = '';
    await for (final chunk in chunks) {
      pending += chunk;
      if (pending.length > retained) {
        yield pending.substring(0, pending.length - retained);
        pending = pending.substring(pending.length - retained);
      }
    }
    pending = pending.replaceFirst(RegExp(r' \[end of text\]\r?\n?$'), '');
    if (pending.isNotEmpty) yield pending;
  }
}
