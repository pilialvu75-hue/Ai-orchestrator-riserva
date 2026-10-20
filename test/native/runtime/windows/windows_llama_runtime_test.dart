import 'package:ai_orchestrator/native/runtime/windows/windows_llama_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundle is independent of working directory and stale user overrides', () {
    expect(
      WindowsLlamaRuntime.resolveExecutable(
        appExecutable: r'C:\Program Files\AI Orchestrator\ai_orchestrator.exe',
        environment: const {'LLAMA_CPP_EXECUTABLE': r'C:\old\missing.exe'},
        fileExists: (file) => file == r'C:\Program Files\AI Orchestrator\llama-completion.exe',
      ),
      r'C:\Program Files\AI Orchestrator\llama-completion.exe',
    );
  });

  test('development fallback preserves an explicit executable path with spaces', () {
    expect(
      WindowsLlamaRuntime.resolveExecutable(
        appExecutable: r'C:\dev\app.exe',
        environment: const {'LLAMA_CPP_EXECUTABLE': ' C:\\runtime folder\\helper.exe '},
        fileExists: (_) => false,
      ),
      r'C:\runtime folder\helper.exe',
    );
  });

  test('Windows generation is finite, bounded and does not mute token stdout', () {
    final args = WindowsLlamaRuntime.arguments(processors: 20);
    expect(args, contains('--no-conversation'));
    expect(args, isNot(contains('--log-disable')));
    expect(args[args.indexOf('-c') + 1], '4096');
    expect(args[args.indexOf('-t') + 1], '8');
    final single = WindowsLlamaRuntime.arguments(processors: 1);
    expect(single[single.indexOf('-t') + 1], '1');
  });

  test('UTF-8 text survives and terminal sentinel is removed at every split', () async {
    const text = 'Risposta: città, perché è così. [end of text]\r\n';
    for (var split = 0; split <= text.length; split++) {
      final output = await WindowsLlamaRuntime.visibleOutput(
        Stream.fromIterable([text.substring(0, split), text.substring(split)]),
      ).join();
      expect(output, 'Risposta: città, perché è così.');
    }
  });

  test('non-terminal content and empty output are preserved honestly', () async {
    expect(await WindowsLlamaRuntime.visibleOutput(Stream.value('4')).join(), '4');
    expect(await WindowsLlamaRuntime.visibleOutput(const Stream.empty()).join(), '');
  });
}
