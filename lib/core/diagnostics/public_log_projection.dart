import 'dart:convert';

/// Public export is a projection, never a redacted copy of arbitrary text.
/// Unknown tags and all free-form payloads are discarded.
String? publicLogProjection(String line) {
  final timestamp = RegExp(r'^\[(\d{4}-\d\d-\d\dT[\d:.+Z-]+)\]')
      .firstMatch(line);
  if (timestamp == null) return null;
  const events = <String>{
    'VOICE_ICON_TAP',
    'TTS_LAZY_INIT',
    'TTS_NATIVE_CREATE_BEGIN',
    'TTS_NATIVE_CREATE_RETURNED',
    'TTS_LAZY_READY',
    'TTS_GENERATE_BEGIN',
    'TTS_AUDIO_READY',
    'TTS_TIMING',
    'TTS_PREPARE_TIMING',
    'TTS_FAIL',
    'TTS_BLOCKED',
    'TTS_WORKER_BEGIN',
    'TTS_WORKER_READY',
    'TTS_WORKER_BUSY',
    'TTS_WORKER_DISCARDED',
    'ONNX_BIND_OK',
    'ONNX_BIND_FAIL',
    'PCM_DIAGNOSTICS',
    'PLAY_BEGIN',
    'PLAY_DONE',
    'NATIVE_PUSH_BACKPRESSURE',
    'STREAM_COMPLETE',
    'PUSH_REJECTED',
    'LOCAL_EXECUTION_CONFIG',
    'RESOURCE_SAMPLE',
    'INFERENCE_TIMING',
    'RESOURCE_PROFILE',
    'RESOURCE_GUARD',
    'INFERENCE_BEGIN',
    'INFERENCE_FINISHED',
    'GENERATION_END',
    'GENERATION_ERROR',
    'FIRST_TOKEN_TIMEOUT',
    'FIRST_TOKEN_FAILURE',
    'MODEL_READY',
    'MODEL_FOUND',
    'MODEL_VALIDATION_OK',
    'MODEL_LOAD',
    'FFI_TIMEOUT',
    'FFI_CANCEL',
    'STALL',
    'TERMINAL_STATE',
    'TOKEN_STREAM',
    'FINAL_RESPONSE',
    'CLOUD_ROUTING',
    'ASSISTANT_WEB_ENRICH',
    'ANDROID_PROCESS_EXIT_HISTORY',
    'FORENSIC_UNCAUGHT_DART_EXCEPTION',
    'FORENSIC_GLOBAL_EXCEPTION_HANDLERS_INSTALLED',
    'DOWNLOAD_START',
    'DOWNLOAD_PROGRESS',
    'DOWNLOAD_COMPLETE',
    'DOWNLOAD_ERROR',
    'DOWNLOAD_FAILED',
    'MODEL_DOWNLOAD_BEGIN',
    'MODEL_DOWNLOAD_COMPLETE',
    'MODEL_DOWNLOAD_FAILED',
    'WORKSHOP_ENGINEER_PROMPT',
    'WORKSHOP_ENGINEER_RETRY',
  };
  // Only contiguous leading tags are eligible; a prompt may contain [TTS_FAIL].
  var rest = line.substring(timestamp.end).trimLeft();
  String? event;
  while (rest.startsWith('[')) {
    final tag = RegExp(r'^\[([A-Z0-9_]+)\]').firstMatch(rest);
    if (tag == null) break;
    if (events.contains(tag[1])) event = tag[1];
    rest = rest.substring(tag.end).trimLeft();
  }
  if (event == null) return null;

  // CLOUD_ROUTING has a fully closed grammar. Never accept free-form values:
  // custom-provider identifiers are reduced to the literal "custom" before
  // they reach this boundary, and any extra field makes the event invalid.
  if (event == 'CLOUD_ROUTING') {
    final routing = RegExp(
      r'^task=(general|reasoning|coding) '
      r'cost=(freeTier|paid|unknown) '
      r'provider=(openAi|gemini|claude|grok|copilot|groq|nvidiaNim|mistral|openRouter|custom) '
      r'decision=(attempt|success|failure) '
      r'reason=(dispatch|completed|rate_limit|quota|authentication|timeout|network|unsupported|unavailable|other)$',
    ).firstMatch(rest);
    if (routing == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': 'CLOUD_ROUTING',
      'task': routing[1]!,
      'cost': routing[2]!,
      'provider': routing[3]!,
      'decision': routing[4]!,
      'reason': routing[5]!,
    });
  }

  // Assistant Web enrichment is public only through a closed telemetry grammar.
  // Session identifiers, query text, result text and exception details are
  // deliberately discarded. This lets Diagnostics prove whether the app-owned
  // Web lookup ran before Cloud/Hybrid inference without exporting conversation
  // contents.
  if (event == 'ASSISTANT_WEB_ENRICH') {
    final attempt = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,80} mode=(cloud|hybrid) '
      r'action=search query_chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (attempt != null) {
      return jsonEncode(<String, Object>{
        'time': timestamp[1]!,
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': attempt[1]!,
        'decision': 'attempt',
        'reason': 'dispatch',
        'query_chars': int.parse(attempt[2]!),
      });
    }

    final success = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,80} mode=(cloud|hybrid) '
      r'status=success result_chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (success != null) {
      return jsonEncode(<String, Object>{
        'time': timestamp[1]!,
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': success[1]!,
        'decision': 'success',
        'reason': 'completed',
        'result_chars': int.parse(success[2]!),
      });
    }

    final unavailable = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,80} mode=(cloud|hybrid) '
      r'status=unavailable reason=tool_unavailable'
      r'(?: action=continue_without_web)?$',
    ).firstMatch(rest);
    if (unavailable != null) {
      return jsonEncode(<String, Object>{
        'time': timestamp[1]!,
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': unavailable[1]!,
        'decision': 'failure',
        'reason': 'tool_unavailable',
      });
    }

    final failed = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,80} mode=(cloud|hybrid) '
      r'status=failed error_type=[A-Za-z_][A-Za-z0-9_]{0,79}'
      r'(?: action=continue_without_web)?$',
    ).firstMatch(rest);
    if (failed != null) {
      return jsonEncode(<String, Object>{
        'time': timestamp[1]!,
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': failed[1]!,
        'decision': 'failure',
        'reason': 'execution_error',
      });
    }

    return null;
  }

  if (event == 'WORKSHOP_ENGINEER_PROMPT') {
    final m = RegExp(
      r'^request=[A-Za-z0-9._:-]{1,120} '
      r'compact=(true|false) chars=(\d{1,9}) '
      r'workspace_files=(\d{1,6}) architect_chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'compact': m[1] == 'true',
      'chars': int.parse(m[2]!),
      'workspace_files': int.parse(m[3]!),
      'architect_chars': int.parse(m[4]!),
    });
  }

  if (event == 'WORKSHOP_ENGINEER_RETRY') {
    final m = RegExp(
      r'^request=[A-Za-z0-9._:-]{1,120} '
      r'(?:execution=[A-Za-z0-9._:-]{1,120} )?'
      r'attempt=(\d{1,3}) '
      r'terminal=(success|timeout|failed|cancelled|modelUnavailable|none)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'attempt': int.parse(m[1]!),
      'terminal': m[2]!,
    });
  }

  // TOKEN_STREAM is exported only for the exact Cloud-provider notice. Token
  // text and arbitrary stream payloads must never leave the device.
  if (event == 'TOKEN_STREAM') {
    final providerNotice = RegExp(
      r'^notice session=[A-Za-z0-9._:-]{1,80} '
      r'notice="cloud_provider:(openAi|gemini|claude|grok|copilot|groq|nvidiaNim|mistral|openRouter)"$',
    ).firstMatch(rest);
    if (providerNotice == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': 'CLOUD_PROVIDER_ATTEMPT',
      'provider': providerNotice[1]!,
    });
  }

  // FINAL_RESPONSE is exported only for a terminal chunk. Intermediate chunks
  // are deliberately discarded so diagnostics cannot mislabel progress as a
  // successful completed request. Session identifiers and response contents
  // are never exported.
  if (event == 'FINAL_RESPONSE') {
    final finalResponse = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,80} attempt=\d{1,9} '
      r'isFinal=(true|false) isError=(true|false) text_len=(\d{1,9})$',
    ).firstMatch(rest);
    if (finalResponse == null || finalResponse[1] != 'true') return null;
    final isError = finalResponse[2] == 'true';
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': isError ? 'FINAL_RESPONSE_ERROR' : 'FINAL_RESPONSE_SUCCESS',
      'is_final': true,
      'text_len': int.parse(finalResponse[3]!),
    });
  }

  if (event == 'INFERENCE_TIMING') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,80}) mode=(local|hybrid|cloud) '
      r'attempt=(\d{1,3}) first_content_ms=(-?\d{1,12}) total_ms=(\d{1,12}) '
      r'reported_tokens=(\d{1,12}) text_chunks=(\d{1,12}) outcome=(success|error)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode({
      'time': timestamp[1]!, 'event': event, 'model': m[1]!, 'mode': m[2]!,
      'attempt': int.parse(m[3]!), 'first_content_ms': int.parse(m[4]!),
      'total_ms': int.parse(m[5]!), 'reported_tokens': int.parse(m[6]!),
      'text_chunks': int.parse(m[7]!), 'outcome': m[8]!,
    });
  }
  if (event == 'RESOURCE_SAMPLE') {
    final m = RegExp(
      r'^available_bytes=(-?\d{1,15}) rss_bytes=(-?\d{1,15}) '
      r'native_heap_bytes=(-?\d{1,15}) critical=(true|false) '
      r'phase=(idle|uninitialized|loading|tokenizing|runtimeUnavailable|ready|inferencing|streaming|completed|timedOut|stalled|ffiMissing|modelMissing|failed) '
      r'gpu_layers=(-?\d{1,6}) decode_calls=(-?\d{1,12})'
      r'(?: total_bytes=(-?\d{1,15}) threshold_bytes=(-?\d{1,15}) '
      r'pressure=(unknown|normal|high|critical) low_memory=(true|false) trim_level=(\d{1,3}) '
      r'n_ctx=(-?\d{1,6}) n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}))?$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode({
      'time': timestamp[1]!,
      'event': event,
      'available_bytes': int.parse(m[1]!),
      'rss_bytes': int.parse(m[2]!),
      'native_heap_bytes': int.parse(m[3]!),
      'critical': m[4] == 'true',
      'phase': m[5]!,
      'gpu_layers': int.parse(m[6]!),
      'decode_calls': int.parse(m[7]!),
      if (m[8] != null) ...{
        'total_bytes': int.parse(m[8]!),
        'threshold_bytes': int.parse(m[9]!),
        'pressure': m[10]!,
        'low_memory': m[11] == 'true',
        'trim_level': int.parse(m[12]!),
        'n_ctx': int.parse(m[13]!),
        'n_batch': int.parse(m[14]!),
        'n_ubatch': int.parse(m[15]!),
      },
    });
  }
  if (event == 'RESOURCE_PROFILE') {
    final m = RegExp(
      r'^reason=(pressure|phi_conservative|baseline) n_ctx=(\d{1,6}) '
      r'n_batch=(\d{1,6}) n_ubatch=(\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode({
      'time': timestamp[1]!,
      'event': event,
      'reason': m[1]!,
      'n_ctx': int.parse(m[2]!),
      'n_batch': int.parse(m[3]!),
      'n_ubatch': int.parse(m[4]!),
    });
  }
  if (event == 'RESOURCE_GUARD') {
    final m = RegExp(r'^action=(defer|cancel) reason=critical_memory$')
        .firstMatch(rest);
    if (m == null) return null;
    return jsonEncode({
      'time': timestamp[1]!,
      'event': event,
      'action': m[1]!,
      'reason': 'critical_memory',
    });
  }

  if (event == 'LOCAL_EXECUTION_CONFIG') {
    final config = RegExp(
      r'^mode=cpu_baseline gpu_layers=0 n_ctx=(\d{1,6}) n_batch=(\d{1,6})$',
    ).firstMatch(rest);
    if (config == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'mode': 'cpu_baseline',
      'gpu_layers': 0,
      'n_ctx': int.parse(config[1]!),
      'n_batch': int.parse(config[2]!),
    });
  }

  final result = <String, Object>{'time': timestamp[1]!, 'event': event};
  // Exact known producer format; do not extract numbers from free-form errors.
  if (event == 'TTS_GENERATE_BEGIN') {
    final m = RegExp(
      r'^family=kokoro lang=(it|fr|en) sid=(\d{1,3}) '
      r'speed=([0-9.]{1,12}) chars=(\d{1,9})(?: phrase=\d{1,9})?$',
    ).firstMatch(rest);
    if (m != null) {
      result.addAll(<String, Object>{
        'family': 'kokoro',
        'lang': m[1]!,
        'sid': int.parse(m[2]!),
        'speed': m[3]!,
        'chars': int.parse(m[4]!),
      });
    }
  }
  if (event == 'TTS_TIMING') {
    final m = RegExp(
      r'^reused=(true|false) load_ms=(\d{1,9}) synthesis_ms=(\d{1,9})$',
    ).firstMatch(rest);
    if (m != null) {
      result.addAll(<String, Object>{
        'reused': m[1] == 'true',
        'load_ms': int.parse(m[2]!),
        'synthesis_ms': int.parse(m[3]!),
      });
    }
  }
  if (event == 'TTS_PREPARE_TIMING') {
    final m = RegExp(r'^asset_ms=(\d{1,9})$').firstMatch(rest);
    if (m != null) result['asset_ms'] = int.parse(m[1]!);
  }
  if (event == 'TTS_FAIL') {
    final reason = RegExp(
      r'^reason=(worker_failed|non_finite_pcm|invalid_pcm|playback_failed)$',
    ).firstMatch(rest);
    if (reason != null) result['error'] = reason[1]!;
    final m = RegExp(
      r'^Bad state: TTS returned invalid audio: (\d{1,9}) of '
      r'(\d{1,9}) samples are non-finite\.$',
    ).firstMatch(rest);
    if (m != null) {
      result.addAll(<String, Object>{
        'error': 'non_finite_pcm',
        'invalid': int.parse(m[1]!),
        'samples': int.parse(m[2]!),
      });
    }
  }
  if (event == 'ANDROID_PROCESS_EXIT_HISTORY') {
    try {
      final data = jsonDecode(rest);
      if (data is Map) {
        for (final key in <String>[
          'timestamp_ms',
          'reason_code',
          'status',
          'pss_kb',
          'rss_kb',
        ]) {
          final value = data[key];
          if (value is int) result[key] = value;
        }
      }
    } catch (_) {
      // Retain the event even without a structured exit record.
    }
  }
  // No arbitrary exception text, stack, prompt, path, ID or token is exported.
  return jsonEncode(result);
}
