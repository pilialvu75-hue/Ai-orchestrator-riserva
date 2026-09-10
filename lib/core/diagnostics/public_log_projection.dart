import 'dart:convert';

/// Public export is a projection, never a redacted copy of arbitrary text.
/// Unknown tags and all free-form payloads are discarded.
String? publicLogProjection(String line) {
  final timestamp =
      RegExp(r'^\[(\d{4}-\d\d-\d\dT[\d:.+Z-]+)\]').firstMatch(line);
  if (timestamp == null) return null;
  const events = <String>{
    'VOICE_ICON_TAP',
    'TTS_LAZY_INIT',
    'TTS_NATIVE_CREATE_BEGIN',
    'TTS_NATIVE_CREATE_RETURNED',
    'TTS_LAZY_READY',
    'TTS_GENERATE_BEGIN',
    'TTS_AUDIO_READY',
    'TTS_FAIL',
    'TTS_BLOCKED',
    'ONNX_BIND_OK',
    'ONNX_BIND_FAIL',
    'PCM_DIAGNOSTICS',
    'PLAY_BEGIN',
    'PLAY_DONE',
    'NATIVE_PUSH_BACKPRESSURE',
    'STREAM_COMPLETE',
    'PUSH_REJECTED',
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

  final result = <String, Object>{'time': timestamp[1]!, 'event': event};
  // Exact known producer format; do not extract numbers from free-form errors.
  if (event == 'TTS_GENERATE_BEGIN') {
    final m = RegExp(
      r'^family=kokoro lang=(it|fr|en) sid=(\d{1,3}) '
      r'speed=([0-9.]{1,12}) chars=(\d{1,9})$',
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
  if (event == 'TTS_FAIL') {
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
