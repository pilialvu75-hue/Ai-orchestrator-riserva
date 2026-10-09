import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/local_model_benchmark_public_projection.dart';

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
    'FIRST_TOKEN_DEADLINE_EXTENDED',
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
    'CLOUD_HTTP_FAILURE',
    'ASSISTANT_WEB_ENRICH',
    'ANDROID_PROCESS_EXIT_HISTORY',
    'FORENSIC_UNCAUGHT_DART_EXCEPTION',
    'FORENSIC_GLOBAL_EXCEPTION_HANDLERS_INSTALLED',
    'DIAGNOSTICS_SESSION',
    'LOCAL_RUNTIME_ERROR',
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
    'WORKSHOP_PLANNER_PROMPT',
    'WORKSHOP_PLANNER_OUTPUT',
    'WORKSHOP_PLANNER_JSON',
    'WORKSHOP_REVIEW_PROMPT',
    'WORKSHOP_REVIEW_RETRY',
    'WORKSHOP_REVIEW_VERDICT',
    'WORKSHOP_REVIEW_BATCH_VERDICT',
    'WORKSHOP_REVIEW_JSON',
    'WORKSHOP_VALIDATION_PROMPT',
    'WORKSHOP_VALIDATION_RETRY',
    'WORKSHOP_VALIDATION_VERDICT',
    'WORKSHOP_GATE_REPAIR',
    'WORKSHOP_DEVICE_ACCEPTANCE',
    'LOCAL_MODEL_BENCH_BEGIN',
    'LOCAL_MODEL_BENCH_DUPLICATE_SKIPPED',
    'LOCAL_MODEL_BENCH_PREFLIGHT',
    'LOCAL_MODEL_BENCH_REASONING_POLICY',
    'LOCAL_MODEL_BENCH_MODEL_SKIPPED',
    'LOCAL_MODEL_BENCH_CASE',
    'LOCAL_MODEL_BENCH_MODEL_END',
    'LOCAL_MODEL_BENCH_THERMAL_GATE',
    'LOCAL_MODEL_BENCH_THERMAL_STOP',
    'LOCAL_MODEL_BENCH_END',
    'LOCAL_VULKAN_SWEEP_BEGIN',
    'LOCAL_VULKAN_SWEEP_CASE',
    'LOCAL_VULKAN_SWEEP_END',
    'POST_GENERATION_MEMORY_RELEASE',
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

  if (event.startsWith('LOCAL_MODEL_BENCH_') ||
      event.startsWith('LOCAL_VULKAN_SWEEP_') ||
      event == 'POST_GENERATION_MEMORY_RELEASE') {
    return localModelBenchmarkPublicProjection(
      event: event,
      rest: rest,
      time: timestamp[1]!,
    );
  }

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

  // HTTP receipts are a closed numeric/enum projection. No raw model, body,
  // headers, token, credential, endpoint, session or free-form error is exported.
  if (event == 'CLOUD_HTTP_FAILURE') {
    final match = RegExp(
      r'^provider=(openAi|gemini|claude|grok|copilot|groq|nvidiaNim|mistral|openRouter|custom) '
      r'status=(4[0-9]{2}|5[0-9]{2}|none) '
      r'model_class=(small|large4|other) '
      r'retry_after_s=(none|[0-9]{1,5}) '
      r'limit_hint=(rps|rpm|tpm|monthly|quota|tier|unknown)$',
    ).firstMatch(rest);
    if (match == null) return null;
    final retry = match[4] == 'none' ? null : int.tryParse(match[4]!);
    if (retry != null && retry > 86400) return null;
    return jsonEncode(<String, Object?>{
      'time': timestamp[1]!,
      'event': 'CLOUD_HTTP_FAILURE',
      'provider': match[1]!,
      'http_status': match[2] == 'none' ? null : int.parse(match[2]!),
      'model_class': match[3]!,
      'retry_after_s': retry,
      'limit_hint': match[5]!,
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

  if (event == 'DIAGNOSTICS_SESSION') {
    final m = RegExp(
      r'^platform=(android|windows|linux|macOS|iOS|fuchsia) '
      r'transport=github_releases enabled=(true|false)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'platform': m[1]!,
      'transport': 'github_releases',
      'enabled': m[2] == 'true',
    });
  }

  if (event == 'LOCAL_RUNTIME_ERROR') {
    final m = RegExp(
      r'^stage=(validation|process_start|stream|process_exit|unknown) '
      r'reason=(unsendable_isolate_object|process_start_failed|process_exit|io_error|other) '
      r'object=(custom_zone|controller_stream|controller_subscription|timer|other|none)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'stage': m[1]!,
      'reason': m[2]!,
      'object': m[3]!,
    });
  }
  if (event == 'WORKSHOP_ENGINEER_PROMPT') {
    final m = RegExp(
      r'^request=[A-Za-z0-9._:-]{1,120} '
      r'compact=(true|false) chars=(\d{1,9}) '
      r'workspace_files=(\d{1,6}) '
      r'(?:replaceable_targets=(\d{1,6}) )?architect_chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'compact': m[1] == 'true',
      'chars': int.parse(m[2]!),
      'workspace_files': int.parse(m[3]!),
      if (m[4] != null) 'replaceable_targets': int.parse(m[4]!),
      'architect_chars': int.parse(m[5]!),
    });
  }

  if (event == 'WORKSHOP_ENGINEER_RETRY') {
    final m = RegExp(
      r'^request=[A-Za-z0-9._:-]{1,120} '
      r'(?:execution=[A-Za-z0-9._:-]{1,120} )?'
      r'attempt=(\d{1,3}) '
      r'(?:reason=(runtime|malformed_output|memory_pressure|prompt_budget) )?'
      r'terminal=(success|timeout|failed|cancelled|modelUnavailable|none)'
      r'(?: chars=(\d{1,9}))?$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'attempt': int.parse(m[1]!),
      if (m[2] != null) 'reason': m[2]!,
      'terminal': m[3]!,
      if (m[4] != null) 'chars': int.parse(m[4]!),
    });
  }

  if (event == 'WORKSHOP_PLANNER_PROMPT') {
    final m = RegExp(
      r'^attempt=(1|2) build_repair=(true|false) chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'attempt': int.parse(m[1]!),
      'build_repair': m[2] == 'true',
      'chars': int.parse(m[3]!),
    });
  }

  if (event == 'WORKSHOP_PLANNER_OUTPUT') {
    final m = RegExp(
      r'^attempt=(1|2) terminal=(success|timeout|failed|cancelled|modelUnavailable|none) '
      r'chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'attempt': int.parse(m[1]!),
      'terminal': m[2]!,
      'chars': int.parse(m[3]!),
    });
  }

  if (event == 'WORKSHOP_PLANNER_JSON') {
    final m = RegExp(
      r'^(?:recovery=(trailing_comma|single_object)|'
      r'rejected=(ambiguous_objects|incomplete_json|invalid_json))$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      if (m[1] != null) 'recovery': m[1]!,
      if (m[2] != null) 'rejected': m[2]!,
    });
  }

  if (event == 'WORKSHOP_REVIEW_PROMPT' ||
      event == 'WORKSHOP_VALIDATION_PROMPT') {
    final m = RegExp(
      r'^compact=(true|false) (?:batch=(\d{1,3})/(\d{1,3}) )?'
      r'chars=(\d{1,9}) files=(\d{1,6}) '
      r'(?:coverage=([a-f0-9]{8}) )?plan_chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'compact': m[1] == 'true',
      if (m[2] != null) 'batch': int.parse(m[2]!),
      if (m[3] != null) 'batches': int.parse(m[3]!),
      'chars': int.parse(m[4]!),
      'files': int.parse(m[5]!),
      if (m[6] != null) 'coverage': m[6]!,
      'plan_chars': int.parse(m[7]!),
    });
  }

  if (event == 'WORKSHOP_REVIEW_RETRY' ||
      event == 'WORKSHOP_VALIDATION_RETRY') {
    final m = RegExp(
      r'^(?:batch=(\d{1,3})/(\d{1,3}) )?attempt=(\d{1,3}) '
      r'(?:reason=(runtime|malformed_output) )?'
      r'terminal=(success|timeout|failed|cancelled|modelUnavailable|none) '
      r'chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      if (m[1] != null) 'batch': int.parse(m[1]!),
      if (m[2] != null) 'batches': int.parse(m[2]!),
      'attempt': int.parse(m[3]!),
      if (m[4] != null) 'reason': m[4]!,
      'terminal': m[5]!,
      'chars': int.parse(m[6]!),
    });
  }

  if (event == 'WORKSHOP_REVIEW_JSON') {
    final m = RegExp(
      r'^batch=(\d{1,3})/(\d{1,3}) '
      r'rejected=invalid_verdict chars=(\d{1,9})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'batch': int.parse(m[1]!),
      'batches': int.parse(m[2]!),
      'rejected': 'invalid_verdict',
      'chars': int.parse(m[3]!),
    });
  }

  if (event == 'WORKSHOP_REVIEW_BATCH_VERDICT') {
    final m = RegExp(
      r'^batch=(\d{1,3})/(\d{1,3}) approved=(true|false) '
      r'files=(\d{1,6}) coverage=([a-f0-9]{8})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'batch': int.parse(m[1]!),
      'batches': int.parse(m[2]!),
      'approved': m[3] == 'true',
      'files': int.parse(m[4]!),
      'coverage': m[5]!,
    });
  }

  if (event == 'WORKSHOP_REVIEW_VERDICT') {
    final batchVerdict = RegExp(
      r'^approved=(true|false) files=(\d{1,6}) batches=(\d{1,3}) '
      r'coverage=([a-f0-9]{8}) findings=(\d{1,6}) warnings=(\d{1,6})$',
    ).firstMatch(rest);
    if (batchVerdict != null) {
      return jsonEncode(<String, Object>{
        'time': timestamp[1]!,
        'event': event,
        'approved': batchVerdict[1] == 'true',
        'files': int.parse(batchVerdict[2]!),
        'batches': int.parse(batchVerdict[3]!),
        'coverage': batchVerdict[4]!,
        'findings': int.parse(batchVerdict[5]!),
        'warnings': int.parse(batchVerdict[6]!),
      });
    }
    final m = RegExp(
      r'^approved=(true|false) summary_chars=(\d{1,9}) '
      r'findings=(\d{1,6}) warnings=(\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'approved': m[1] == 'true',
      'summary_chars': int.parse(m[2]!),
      'findings': int.parse(m[3]!),
      'warnings': int.parse(m[4]!),
    });
  }

  if (event == 'WORKSHOP_VALIDATION_VERDICT') {
    final m = RegExp(
      r'^valid=(true|false) summary_chars=(\d{1,9}) '
      r'checks=(\d{1,6}) warnings=(\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'valid': m[1] == 'true',
      'summary_chars': int.parse(m[2]!),
      'checks': int.parse(m[3]!),
      'warnings': int.parse(m[4]!),
    });
  }

  if (event == 'WORKSHOP_GATE_REPAIR') {
    final m = RegExp(
      r'^source=(review|validation) attempt=(\d{1,3}) '
      r'summary_chars=(\d{1,9}) issues=(\d{1,6}) warnings=(\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'source': m[1]!,
      'attempt': int.parse(m[2]!),
      'summary_chars': int.parse(m[3]!),
      'issues': int.parse(m[4]!),
      'warnings': int.parse(m[5]!),
    });
  }

  if (event == 'WORKSHOP_DEVICE_ACCEPTANCE') {
    final m = RegExp(
      r'^status=(pending|passed|failed) '
      r'failure_stage=(none|modelRuntime|parsing|review|validation|build|install|launch) '
      r'completed_tasks=(\d{1,4}) total_tasks=(\d{1,4}) '
      r'install_attempted=(true|false) installer_opened=(true|false) '
      r'app_opened=(true|false|unknown) '
      r'host_commit=([0-9a-f]{40}|unknown) '
      r'artifact_sha=([0-9a-f]{64}|none)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'status': m[1]!,
      'failure_stage': m[2]!,
      'completed_tasks': int.parse(m[3]!),
      'total_tasks': int.parse(m[4]!),
      'install_attempted': m[5] == 'true',
      'installer_opened': m[6] == 'true',
      'app_opened': m[7]!,
      'host_commit': m[8]!,
      'artifact_sha': m[9]!,
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

  if (event == 'FIRST_TOKEN_DEADLINE_EXTENDED') {
    final m = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,120} '
      r'elapsed_ms=(\d{1,12}) soft_timeout_ms=(\d{1,12}) '
      r'hard_timeout_ms=(\d{1,12}) decode_baseline=(-?\d{1,12}) '
      r'decode_current=(-?\d{1,12}) reason=native_decode_progress$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'elapsed_ms': int.parse(m[1]!),
      'soft_timeout_ms': int.parse(m[2]!),
      'hard_timeout_ms': int.parse(m[3]!),
      'decode_baseline': int.parse(m[4]!),
      'decode_current': int.parse(m[5]!),
      'reason': 'native_decode_progress',
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
      'time': timestamp[1]!,
      'event': event,
      'model': m[1]!,
      'mode': m[2]!,
      'attempt': int.parse(m[3]!),
      'first_content_ms': int.parse(m[4]!),
      'total_ms': int.parse(m[5]!),
      'reported_tokens': int.parse(m[6]!),
      'text_chunks': int.parse(m[7]!),
      'outcome': m[8]!,
    });
  }
  if (event == 'RESOURCE_SAMPLE') {
    final current = RegExp(
      r'^available_bytes=(-?\d{1,15}) rss_bytes=(-?\d{1,15}) '
      r'native_heap_bytes=(-?\d{1,15}) battery_temp_decic=(-?\d{1,6}) '
      r'critical=(true|false) '
      r'phase=(idle|uninitialized|loading|tokenizing|runtimeUnavailable|ready|inferencing|streaming|completed|timedOut|stalled|ffiMissing|modelMissing|failed) '
      r'gpu_layers=(-?\d{1,6}) decode_calls=(-?\d{1,12}) '
      r'prefill_ms=(-?\d{1,12})'
      r'(?: total_bytes=(-?\d{1,15}) threshold_bytes=(-?\d{1,15}) '
      r'pressure=(unknown|normal|high|critical) low_memory=(true|false) trim_level=(\d{1,3}) '
      r'n_ctx=(-?\d{1,6}) n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}))?$',
    ).firstMatch(rest);
    if (current != null) {
      return jsonEncode({
        'time': timestamp[1]!,
        'event': event,
        'available_bytes': int.parse(current[1]!),
        'rss_bytes': int.parse(current[2]!),
        'native_heap_bytes': int.parse(current[3]!),
        'battery_temp_decic': int.parse(current[4]!),
        'critical': current[5] == 'true',
        'phase': current[6]!,
        'gpu_layers': int.parse(current[7]!),
        'decode_calls': int.parse(current[8]!),
        'prefill_ms': int.parse(current[9]!),
        if (current[10] != null) ...{
          'total_bytes': int.parse(current[10]!),
          'threshold_bytes': int.parse(current[11]!),
          'pressure': current[12]!,
          'low_memory': current[13] == 'true',
          'trim_level': int.parse(current[14]!),
          'n_ctx': int.parse(current[15]!),
          'n_batch': int.parse(current[16]!),
          'n_ubatch': int.parse(current[17]!),
        },
      });
    }

    // Historical persisted logs remain exportable through the old closed
    // grammar. New fields are never inferred when they were not measured.
    final legacy = RegExp(
      r'^available_bytes=(-?\d{1,15}) rss_bytes=(-?\d{1,15}) '
      r'native_heap_bytes=(-?\d{1,15}) critical=(true|false) '
      r'phase=(idle|uninitialized|loading|tokenizing|runtimeUnavailable|ready|inferencing|streaming|completed|timedOut|stalled|ffiMissing|modelMissing|failed) '
      r'gpu_layers=(-?\d{1,6}) decode_calls=(-?\d{1,12})'
      r'(?: total_bytes=(-?\d{1,15}) threshold_bytes=(-?\d{1,15}) '
      r'pressure=(unknown|normal|high|critical) low_memory=(true|false) trim_level=(\d{1,3}) '
      r'n_ctx=(-?\d{1,6}) n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}))?$',
    ).firstMatch(rest);
    if (legacy == null) return null;
    return jsonEncode({
      'time': timestamp[1]!,
      'event': event,
      'available_bytes': int.parse(legacy[1]!),
      'rss_bytes': int.parse(legacy[2]!),
      'native_heap_bytes': int.parse(legacy[3]!),
      'critical': legacy[4] == 'true',
      'phase': legacy[5]!,
      'gpu_layers': int.parse(legacy[6]!),
      'decode_calls': int.parse(legacy[7]!),
      if (legacy[8] != null) ...{
        'total_bytes': int.parse(legacy[8]!),
        'threshold_bytes': int.parse(legacy[9]!),
        'pressure': legacy[10]!,
        'low_memory': legacy[11] == 'true',
        'trim_level': int.parse(legacy[12]!),
        'n_ctx': int.parse(legacy[13]!),
        'n_batch': int.parse(legacy[14]!),
        'n_ubatch': int.parse(legacy[15]!),
      },
    });
  }
  if (event == 'RESOURCE_PROFILE') {
    final m = RegExp(
      r'^reason=(pressure|phi_conservative|phi_gpu_conservative|phi_memory_recovery|device_memory_budget|device_memory_conservative|device_gpu_conservative|baseline) n_ctx=(\d{1,6}) '
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
      r'^mode=(cpu_baseline|vulkan) gpu_layers=(\d{1,3}) n_ctx=(\d{1,6}) n_batch=(\d{1,6})$',
    ).firstMatch(rest);
    if (config == null) return null;
    final layers = int.parse(config[2]!);
    if ((config[1] == 'cpu_baseline' && layers != 0) ||
        (config[1] == 'vulkan' && layers == 0)) return null;
    return jsonEncode(<String, Object>{
      'time': timestamp[1]!,
      'event': event,
      'mode': config[1]!,
      'gpu_layers': layers,
      'n_ctx': int.parse(config[3]!),
      'n_batch': int.parse(config[4]!),
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
        final cause = data['managed_cause'];
        if (const <String>{
          'foreground_start_timeout',
          'foreground_start_disallowed',
          'foreground_bad_notification',
          'security_exception',
          'managed_other',
        }.contains(cause)) {
          result['managed_cause'] = cause;
        }

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
