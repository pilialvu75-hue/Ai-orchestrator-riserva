import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
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
