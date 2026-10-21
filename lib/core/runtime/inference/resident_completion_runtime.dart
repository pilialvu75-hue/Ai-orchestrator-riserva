import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

class ResidentRuntimeBusy implements Exception {}

/// One local, authenticated process and one cache slot. Nothing is persisted.
/// A different model or conversation always starts a fresh process.
class ResidentCompletionRuntime {
  ResidentCompletionRuntime({this.idleTimeout = const Duration(minutes: 2)});

  final Duration idleTimeout;
  Process? _process;
  HttpClient? _client;
  int? _port;
  String? _key;
  String? _identity;
  Timer? _idle;
  bool _busy = false;
  CancellationToken? _activeCancellation;

  Stream<String> generate({
    required String executable,
    required String modelPath,
    required String sessionId,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required double topP,
    required double repeatPenalty,
    required int threads,
    required CancellationToken cancellation,
    void Function(int cached, int evaluated)? onPromptUsage,
  }) async* {
    if (_busy) throw ResidentRuntimeBusy();
    if (cancellation.isCancelled) throw StateError('Inference cancelled.');
    _busy = true;
    _idle?.cancel();
    _activeCancellation = cancellation;
    cancellation.onCancel(() {
      if (identical(_activeCancellation, cancellation)) unawaited(close());
    });
    try {
      await _ensureStarted(executable, modelPath, sessionId, threads, cancellation);
      if (cancellation.isCancelled) throw StateError('Inference cancelled.');
      final request = await _request('POST', '/completion');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'prompt': prompt, 'n_predict': maxTokens, 'temperature': temperature,
        'top_p': topP, 'top_k': 40, 'repeat_penalty': repeatPenalty,
        'cache_prompt': true, 'id_slot': 0, 'stream': true,
      }));
      final response = await request.close().timeout(const Duration(minutes: 4));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Local inference returned HTTP ${response.statusCode}.');
      }
      var stopped = false;
      await for (final line in response.transform(utf8.decoder)
          .transform(const LineSplitter()).timeout(const Duration(minutes: 4))) {
        if (cancellation.isCancelled) throw StateError('Inference cancelled.');
        if (!line.startsWith('data:')) continue;
        final raw = line.substring(5).trim();
        if (raw == '[DONE]') continue;
        final value = jsonDecode(raw) as Map<String, dynamic>;
        if (value.containsKey('error')) throw StateError('Local generation failed.');
        final content = value['content'] as String? ?? '';
        if (content.isNotEmpty) yield content;
        if (value['stop'] == true) {
          stopped = true;
          final timings = value['timings'];
          if (timings is Map) {
            onPromptUsage?.call((timings['cache_n'] as num?)?.toInt() ?? 0,
                (timings['prompt_n'] as num?)?.toInt() ?? 0);
          }
        }
      }
      if (cancellation.isCancelled) throw StateError('Inference cancelled.');
      if (!stopped) throw StateError('Local inference ended without completion.');
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _activeCancellation = null;
      _busy = false;
      if (_process != null) _idle = Timer(idleTimeout, () => unawaited(close()));
    }
  }

  Future<HttpClientRequest> _request(String method, String endpoint) async {
    final request = await _client!.openUrl(method,
        Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: endpoint));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_key');
    return request;
  }

  Future<void> _ensureStarted(String executable, String model, String session,
      int threads, CancellationToken cancellation) async {
    final identity = '$executable\u0000$model\u0000$session';
    if (_process != null && _identity == identity) return;
    await close();
    if (cancellation.isCancelled) throw StateError('Inference cancelled.');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = probe.port;
    await probe.close();
    final random = Random.secure();
    _key = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final process = await Process.start(executable, [
      '-m', model, '--host', '127.0.0.1', '--port', '$_port', '--api-key', _key!,
      '-c', '4096', '-t', '${threads.clamp(1, 8)}', '-ngl', '0', '--parallel', '1',
      '--no-slots', '--sleep-idle-seconds', '120',
    ]);
    _process = process;
    _identity = identity;
    // Drain both pipes. Neither prompts, process arguments nor credentials go
    // to diagnostics. The API returns only bounded error status to callers.
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    int? exitCode;
    unawaited(process.exitCode.then((value) {
      exitCode = value;
      if (identical(_process, process)) {
        _process = null;
        _identity = null;
      }
    }));
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (cancellation.isCancelled) throw StateError('Inference cancelled.');
      if (exitCode != null) throw StateError('Local runtime failed to start.');
      try {
        final request = await _request('GET', '/health');
        final response = await request.close().timeout(const Duration(seconds: 2));
        final ready = response.statusCode == HttpStatus.ok;
        await response.drain<void>();
        if (ready) return;
      } on IOException {
        // The socket is unavailable until model startup reaches the HTTP loop.
      } on TimeoutException {
        // Retry within the bounded startup window.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('Local model startup timed out.');
  }

  Future<void> close() async {
    _idle?.cancel();
    _idle = null;
    final process = _process;
    _process = null;
    _identity = null;
    _client?.close(force: true);
    _client = null;
    _key = null;
    _port = null;
    if (process != null) {
      process.kill();
      try { await process.exitCode.timeout(const Duration(seconds: 3)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); }
    }
  }
}
