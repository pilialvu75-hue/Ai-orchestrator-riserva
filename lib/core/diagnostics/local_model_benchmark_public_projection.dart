import 'dart:convert';

String? localModelBenchmarkPublicProjection({
  required String event,
  required String rest,
  required String time,
}) {
  if (event == 'LOCAL_MODEL_BENCH_BEGIN') {
    final m = RegExp(
      r'^models=[A-Za-z0-9_.,-]{1,240} cases=(\d{1,3}) '
      r'max_tokens=(\d{1,6}) temperature=([0-9.]{1,8})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'cases': int.parse(m[1]!),
      'max_tokens': int.parse(m[2]!),
      'temperature': double.parse(m[3]!),
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_CASE') {
    final m = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'case=(sdd_typo_first|vulkan_fact|ram_fact|arithmetic|ssd_direct|'
      r'sdd_repeat_empty|sdd_after_history|ssd_hdd_followup) '
      r'score=(\d{1,3})/(\d{1,3}) forbidden_hits=(\d{1,3}) '
      r'first_content_ms=(\d{1,12}) total_ms=(\d{1,12}) '
      r'reported_tokens=(\d{1,12}) decode_tokens_s=([0-9.]{1,16}) '
      r'gpu_layers=(-?\d{1,6}) n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}) '
      r'pressure=(unknown|normal|high|critical)->(unknown|normal|high|critical)'
      r'(?: start_available_bytes=(-?\d{1,15}) end_available_bytes=(-?\d{1,15}))?'
      r'(?: session=(cold|warm|unknown)->(kept|released|unknown))?$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'case': m[2]!,
      'score': int.parse(m[3]!),
      'max_score': int.parse(m[4]!),
      'forbidden_hits': int.parse(m[5]!),
      'first_content_ms': int.parse(m[6]!),
      'total_ms': int.parse(m[7]!),
      'reported_tokens': int.parse(m[8]!),
      'decode_tokens_s': double.parse(m[9]!),
      'gpu_layers': int.parse(m[10]!),
      'n_batch': int.parse(m[11]!),
      'n_ubatch': int.parse(m[12]!),
      'start_pressure': m[13]!,
      'end_pressure': m[14]!,
      if (m[15] != null) 'start_available_bytes': int.parse(m[15]!),
      if (m[16] != null) 'end_available_bytes': int.parse(m[16]!),
      if (m[17] != null) 'session_start': m[17]!,
      if (m[18] != null) 'session_end': m[18]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_MODEL_END') {
    final m = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'quality=(\d{1,3})/(\d{1,3}) '
      r'avg_first_content_ms=([0-9.]{1,16}) '
      r'avg_total_ms=([0-9.]{1,16}) '
      r'avg_decode_tokens_s=([0-9.]{1,16})'
      r'(?: sdd_repeat_consistent=(true|false|na))?$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'score': int.parse(m[2]!),
      'max_score': int.parse(m[3]!),
      'avg_first_content_ms': double.parse(m[4]!),
      'avg_total_ms': double.parse(m[5]!),
      'avg_decode_tokens_s': double.parse(m[6]!),
      if (m[7] != null) 'sdd_repeat_consistent': m[7]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_END') {
    final m = RegExp(r'^models=(\d{1,3}) status=(success|failed)$')
        .firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'models': int.parse(m[1]!),
      'status': m[2]!,
    });
  }

  if (event == 'POST_GENERATION_MEMORY_RELEASE') {
    final m = RegExp(
      r'^session=[A-Za-z0-9._:-]{1,120} native_session=\d{1,12} '
      r'modelId=(phi3_5_mini|nemotron3_nano_4b) '
      r'available_bytes=(-?\d{1,15}) threshold_bytes=(-?\d{1,15}) '
      r'pressure=(high|critical)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'available_bytes': int.parse(m[2]!),
      'threshold_bytes': int.parse(m[3]!),
      'pressure': m[4]!,
    });
  }

  return null;
}
