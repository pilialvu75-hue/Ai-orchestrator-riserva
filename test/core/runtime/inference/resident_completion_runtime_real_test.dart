import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ai_orchestrator/core/runtime/inference/assistant_resident_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_process_lease.dart';

class _NoCliProvider extends LocalRuntimeProvider {
  @override
  Future<Process> startRuntimeProcess(String executable, List<String> arguments) =>
      throw StateError('Resident smoke test must not fall back to CLI.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = Platform.environment['AI_ORCHESTRATOR_WINDOWS_SMOKE_HELPER'];
  final model = Platform.environment['AI_ORCHESTRATOR_WINDOWS_SMOKE_MODEL'];
  final server = helper == null ? null : p.join(p.dirname(helper), 'runtime-modern', 'llama-server.exe');
  final skip = !Platform.isWindows || server == null || model == null || !File(server).existsSync();

  test('closing the Windows lifetime lease terminates only its child process', () async {
    final child = await Process.start('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60']);
    ResidentProcessLease? lease;
    try {
      lease = ResidentProcessLease.attach(child.pid);
      expect(lease, isNotNull);
      lease!.close();
      await child.exitCode.timeout(const Duration(seconds: 5));
    } finally {
      lease?.close();
      child.kill();
    }
  }, skip: !Platform.isWindows);

  test('real resident cache is reused only within one conversation', () async {
    final runtime = ResidentCompletionRuntime();
    final cached = <int>[];
    Future<String> generate(String session, String prompt) => runtime.generate(
      executable: server!, modelPath: model!, sessionId: session, prompt: prompt,
      maxTokens: 8, temperature: 0, topP: 0.9, repeatPenalty: 1.1, threads: 2,
      cancellation: CancellationToken(), onPromptUsage: (cache, evaluated) => cached.add(cache),
    ).join();
    try {
      final first = await generate('one', 'Once upon a time');
      expect(first.trim(), isNotEmpty);
      final second = await generate('one', 'Once upon a time$first');
      expect(second.trim(), isNotEmpty);
      expect(cached[1], greaterThan(0));
      await generate('two', 'Once upon a time');
      expect(cached[2], 0, reason: 'A different conversation must not inherit KV state.');
    } finally { await runtime.close(); }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('real Assistant wrapper returns success without CLI markers', () async {
    final delegate = _NoCliProvider();
    final provider = AssistantResidentLocalRuntimeProvider(delegate: delegate, executable: () => server);
    try {
      final chunks = await provider.streamInference(request: InferenceRequest(
        sessionId: 'wrapper', prompt: 'Once upon a time', modelId: 'tinyllama',
        modelPath: model, maxTokens: 8, temperature: 0,
      ), cancellationToken: CancellationToken()).toList();
      expect(chunks.last.isFinal, isTrue);
      expect(chunks.last.isError, isFalse, reason: chunks.last.errorMessage);
      expect(chunks.last.text.trim(), isNotEmpty);
      expect(chunks.last.text, isNot(contains('[end of text]')));
      expect(delegate.isRuntimeVerified(modelPath: model), isTrue);
    } finally { await provider.dispose(); }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('real resident request cancellation closes the active generation', () async {
    final runtime = ResidentCompletionRuntime();
    final token = CancellationToken();
    try {
      final stream = runtime.generate(executable: server!, modelPath: model!, sessionId: 'cancel',
        prompt: 'Once upon a time', maxTokens: 1000, temperature: 0,
        topP: 0.9, repeatPenalty: 1.1, threads: 2, cancellation: token);
      await expectLater(stream.map((value) { token.cancel(); return value; }).toList(), throwsA(anything));
      expect(token.isCancelled, isTrue);
    } finally { await runtime.close(); }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
