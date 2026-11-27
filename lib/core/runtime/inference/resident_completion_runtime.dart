import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_process_lease.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_engine_process_tracker.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_memory_guard.dart';

/// Native terminal statistics. Missing or malformed fields remain unknown.
class ResidentGenerationMetrics {
  const ResidentGenerationMetrics({
    this.generatedTokens,
    this.decodeMilliseconds,
    this.tokensPerSecond,
  });

  factory ResidentGenerationMetrics.fromTimings(Object? timings) {
    final map = timings is Map ? timings : const {};
    double? nonnegative(Object? value) =>
        value is num && value.isFinite && value >= 0
            ? value.toDouble()
            : null;
    final count = map['predicted_n'];
    return ResidentGenerationMetrics(
      generatedTokens: count is int && count >= 0 ? count : null,
      decodeMilliseconds: nonnegative(map['predicted_ms']),
      tokensPerSecond: nonnegative(map['predicted_per_second']),
    );
  }

  final int? generatedTokens;
  final double? decodeMilliseconds;
  final double? tokensPerSecond;
}

class ResidentRuntimeBusy implements Exception {}

/// The engine completed transport but exhausted the requested output budget.
class ResidentGenerationLimitReached implements Exception {}

/// One local, authenticated process and one cache slot. Nothing is persisted.
/// A different model or conversation always starts a fresh process.
class ResidentCompletionRuntime {
  ResidentCompletionRuntime({
    this.idleTimeout = const Duration(minutes: 5),
    this.contextSize = 4096,
    this.windowsResources,
  }) : assert(contextSize > 0);

  final Duration idleTimeout;
  final int contextSize;
  final ResourceMonitor? windowsResources;

  WindowsMemoryGuard? _memoryGuard() {
    final resources = windowsResources;
    return resources == null ? null : WindowsMemoryGuard(resources, abort: () {
      _process?.kill();
    });
  }
  Process? _process;
  ResidentProcessLease? _lease;
  HttpClient? _client;
  int? _port;
  String? _key;
  String? _identity;
  Timer? _idle;
  bool _busy = false;
  CancellationToken? _activeCancellation;
  int? get processId => _process?.pid;
  ResidentGenerationMetrics? _lastGenerationMetrics;
  ResidentGenerationMetrics? get lastGenerationMetrics => _lastGenerationMetrics;

  /// Load the engine without generating or adding any conversation tokens.
  Future<void> prepare({required String executable, required String modelPath,
      required String sessionId, required int threads, String? device, int? batchSize,
      int? ubatchSize, bool flashAttention = false}) async {
    if (_busy) throw ResidentRuntimeBusy();
    _busy = true;
    _idle?.cancel();
    final memory = _memoryGuard();
    try {
      await memory?.start();
      await _ensureStarted(executable, modelPath, sessionId, threads,
          CancellationToken(), batchSize, ubatchSize, device, flashAttention, memory, null);
      memory?.check();
    } catch (_) {
      await close();
      memory?.check();
      rethrow;
    } finally {
      memory?.release();
      _busy = false;
      if (_process != null) _idle = Timer(idleTimeout, () => unawaited(close()));
    }
  }

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
    int? batchSize,
    int? ubatchSize,
    bool flashAttention = false,
    String? device,
    int? gpuLayers,
    required CancellationToken cancellation,
    void Function(int cached, int evaluated)? onPromptUsage,
    bool rejectTokenLimit = false,
  }) async* {
    if (_busy) throw ResidentRuntimeBusy();
    // A rejected concurrent call must not clear the active request's data.
    _lastGenerationMetrics = null;
    if (cancellation.isCancelled) throw StateError('Inference cancelled.');
    _busy = true;
    _idle?.cancel();
    _activeCancellation = cancellation;
    cancellation.onCancel(() {
      if (identical(_activeCancellation, cancellation)) unawaited(close());
    });
    final memory = _memoryGuard();
    try {
      await memory?.start();
      if (batchSize != null && (batchSize < 1 || batchSize > 2048)) {
        throw ArgumentError.value(batchSize, 'batchSize');
      }
      if (ubatchSize != null && (ubatchSize < 1 || ubatchSize > 2048 ||
          (batchSize != null && ubatchSize > batchSize))) {
        throw ArgumentError.value(ubatchSize, 'ubatchSize');
      }
      if (device != null && !RegExp(r'^(?:Vulkan|CUDA)\d+$').hasMatch(device)) {
        throw ArgumentError.value(device, 'device');
      }
      resolveGpuLayers(device, gpuLayers);
      final firstContentWatch = Stopwatch()..start();
      var sawContent = false;
      await _ensureStarted(executable, modelPath, sessionId, threads, cancellation,
          batchSize, ubatchSize, device, flashAttention, memory, gpuLayers);
      memory?.check();
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
      var tokenLimitReached = false;
      ResidentGenerationMetrics? terminalMetrics;
      await for (final line in response.transform(utf8.decoder)
          .transform(const LineSplitter()).timeout(const Duration(minutes: 4))) {
        memory?.check();
        if (cancellation.isCancelled) throw StateError('Inference cancelled.');
        if (!line.startsWith('data:')) continue;
        final raw = line.substring(5).trim();
        if (raw == '[DONE]') continue;
        final value = jsonDecode(raw) as Map<String, dynamic>;
        if (value.containsKey('error')) throw StateError('Local generation failed.');
        final content = value['content'] as String? ?? '';
        if (content.isNotEmpty) {
          if (!sawContent) {
            sawContent = true;
            RuntimeEventLog.instance.emit('[ASSISTANT_RESIDENT_PHASE] phase=first_content elapsed_ms=${firstContentWatch.elapsedMilliseconds}');
          }
          yield content;
        }
        if (value['stop'] == true) {
          stopped = true;
          tokenLimitReached = value['stop_type'] == 'limit';
          final timings = value['timings'];
          terminalMetrics = ResidentGenerationMetrics.fromTimings(timings);
          if (timings is Map) {
            onPromptUsage?.call((timings['cache_n'] as num?)?.toInt() ?? 0,
                (timings['prompt_n'] as num?)?.toInt() ?? 0);
          }
        }
      }
      if (cancellation.isCancelled) throw StateError('Inference cancelled.');
      memory?.check();
      if (!stopped) throw StateError('Local inference ended without completion.');
      if (rejectTokenLimit && tokenLimitReached) throw ResidentGenerationLimitReached();
      _lastGenerationMetrics = terminalMetrics;
    } catch (error) {
      if (error is! ResidentGenerationLimitReached || memory?.tripped == true) await close();
      memory?.check();
      rethrow;
    } finally {
      memory?.release();
      _activeCancellation = null;
      _busy = false;
      if (_process != null) _idle = Timer(idleTimeout, () => unawaited(close()));
    }
  }

  Future<HttpClientRequest> _request(String method, String endpoint) async {
    final request = await _client!.openUrl(method,
        Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: endpoint));
    // Model startup and shutdown can close a server-side keep-alive socket.
    // A fresh loopback connection avoids reusing it for the next generation.
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_key');
    return request;
  }

  Future<void> _ensureStarted(String executable, String model, String session,
      int threads, CancellationToken cancellation, int? batchSize, int? ubatchSize,
      String? device, bool flashAttention, WindowsMemoryGuard? memory, int? gpuLayers) async {
    final layers = resolveGpuLayers(device, gpuLayers);
    final identity = '$executable\u0000$model\u0000$session\u0000$batchSize\u0000$ubatchSize\u0000$device\u0000$flashAttention\u0000$layers';
    if (_process != null && _identity == identity) return;
    final startupWatch = Stopwatch()..start();
    await close();
    if (cancellation.isCancelled) throw StateError('Inference cancelled.');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = probe.port;
    await probe.close();
    final random = Random.secure();
    _key = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    memory?.check();
    if (cancellation.isCancelled) throw StateError('Inference cancelled.');
    final process = await Process.start(executable, [
      '-m', model, '--host', '127.0.0.1', '--port', '$_port', '--api-key', _key!,
      '-c', '$contextSize', '-t', '${threads.clamp(1, 8)}', '-ngl', '$layers', '--parallel', '1',
      // Avoid an extra synthetic generation before the first real request.
      // Measured with this pinned Vulkan package; CPU/legacy paths unchanged.
      if (device != null) ...['--device', device, '--no-warmup'],
      if (flashAttention) ...['--flash-attn', 'on'],
      '--threads-batch', '${threads.clamp(1, 8)}',
      // Bound recurrent-state rollback only for an explicitly measured profile.
      if (batchSize != null) ...['--batch-size', '$batchSize'],
      if (ubatchSize != null) ...['--ubatch-size', '$ubatchSize'],
      '--no-slots', '--sleep-idle-seconds', '${idleTimeout.inSeconds.clamp(1, 86400)}',
    ]);
    RuntimeEventLog.instance.emit('[ASSISTANT_RESIDENT_PHASE] phase=process_started elapsed_ms=${startupWatch.elapsedMilliseconds}');
    _process = process;
    WindowsEngineProcessTracker.instance.track(process);
    _lease = ResidentProcessLease.attach(process.pid);
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
    memory?.check();
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      memory?.check();
      if (cancellation.isCancelled) throw StateError('Inference cancelled.');
      if (exitCode != null) throw StateError('Local runtime failed to start.');
      try {
        final request = await _request('GET', '/health');
        final response = await request.close().timeout(const Duration(seconds: 2));
        final ready = response.statusCode == HttpStatus.ok;
        await response.drain<void>();
        if (ready) {
          RuntimeEventLog.instance.emit('[ASSISTANT_RESIDENT_PHASE] phase=health_ready elapsed_ms=${startupWatch.elapsedMilliseconds}');
          return;
        }
      } on IOException {
        // The socket is unavailable until model startup reaches the HTTP loop.
      } on TimeoutException {
        // Retry within the bounded startup window.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('Local model startup timed out.');
  }

  /// Only an idle resident can be released for a new memory admission.
  Future<void> releaseForAdmission() async {
    if (_busy) throw ResidentRuntimeBusy();
    await close();
  }

  /// Legacy defaults remain identical. Explicit partial offload is bounded
  /// and must name the selected device; CPU cannot accept GPU layers.
  static int resolveGpuLayers(String? device, int? requested) {
    if (requested == null) return device == null ? 0 : 99;
    if (device == null || requested < 1 || requested > 513) {
      throw ArgumentError.value(requested, 'gpuLayers');
    }
    return requested;
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
    _lease?.close();
    _lease = null;
    if (process != null) {
      process.kill();
      try { await process.exitCode.timeout(const Duration(seconds: 3)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); }
    }
  }
}



