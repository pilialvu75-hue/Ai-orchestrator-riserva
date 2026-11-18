import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProcessProvider extends LocalRuntimeProvider {
  _ProcessProvider(this.script);
  final String script;
  late String executable;
  late List<String> arguments;

  @override
  Future<Process> startRuntimeProcess(String executable, List<String> arguments) {
    this.executable = executable;
    this.arguments = arguments;
    return Process.start('powershell.exe', ['-NoProfile', '-File', script]);
  }
}

void main() {
  group('Windows process completion', () {
    late Directory temporary;
    late File model;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('windows runtime spaces ');
      model = File('${temporary.path}/test model.gguf');
      await model.writeAsBytes([0x47, 0x47, 0x55, 0x46]);
    });
    tearDown(() async => temporary.delete(recursive: true));

    Future<_ProcessProvider> run(String body) async {
      final script = File('${temporary.path}/process.ps1');
      await script.writeAsString(body);
      final provider = _ProcessProvider(script.path);
      await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'windows-test', prompt: 'Calculate 17 * 23',
          modelId: 'phi3_5_mini', modelPath: model.path, maxTokens: 16,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      return provider;
    }

    test('drains final buffered stdout before marking the runtime verified', () async {
      final provider = await run("[Console]::Out.Write('391 [end of text]'); exit 0");
      expect(provider.isRuntimeVerified(modelPath: model.path), isTrue);
      expect(provider.arguments, contains(model.path));
      expect(provider.arguments, contains('--no-conversation'));
      expect(provider.arguments, isNot(contains('--log-disable')));
    });

    test('reports CLI startup, first output and exit without exposing text', () async {
      final previousCount = RuntimeEventLog.instance.entries.length;
      await run("[Console]::Out.Write('synthetic secret test output'); exit 0");

      final timing = RuntimeEventLog.instance.entries
          .skip(previousCount)
          .map((entry) => entry.message)
          .where((message) => message.contains('backend=process_cli'))
          .toList();
      expect(
        timing.any((message) =>
            message.startsWith('[GENERATION_START]') &&
            message.contains('gpu_layers=0') &&
            message.contains('process_launch_ms=')),
        isTrue,
      );
      expect(
        timing.where((message) =>
            message.startsWith('[FIRST_TOKEN]') &&
            message.contains('first_visible_output_ms=')).length,
        1,
      );
      expect(
        timing.any((message) =>
            message.startsWith('[GENERATION_END]') &&
            message.contains('total_ms=') &&
            message.contains('exit_code=0')),
        isTrue,
      );
      expect(timing.join('\n'), isNot(contains('synthetic secret test output')));
      expect(timing.join('\n'), isNot(contains(model.path)));
    });

    test('partial stdout plus a failed process is never marked verified', () async {
      final provider = await run("[Console]::Out.Write('partial'); exit 7");
      expect(provider.isRuntimeVerified(modelPath: model.path), isFalse);
    });

    test('successful exit without generated text is never marked verified', () async {
      final provider = await run('exit 0');
      expect(provider.isRuntimeVerified(modelPath: model.path), isFalse);
    });
  }, skip: !Platform.isWindows);
}
