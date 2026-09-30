import 'dart:convert';

String? localModelBenchmarkPublicProjection({
  required String event,
  required String rest,
  required String time,
}) {
  if (event == 'LOCAL_MODEL_BENCH_BEGIN') {
    final current = RegExp(
      r'^models=([A-Za-z0-9_.,-]{1,480}) '
      r'catalogs=([A-Za-z0-9_.,-]{1,480}) cases=(\d{1,3}) '
      r'max_tokens=(\d{1,6}) temperature=([0-9.]{1,8})$',
    ).firstMatch(rest);
    if (current != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'models': current[1]!.split(','),
        'catalogs': current[2]!.split(','),
        'cases': int.parse(current[3]!),
        'max_tokens': int.parse(current[4]!),
        'temperature': double.parse(current[5]!),
      });
    }

    final legacy = RegExp(
      r'^models=[A-Za-z0-9_.,-]{1,480} cases=(\d{1,3}) '
      r'max_tokens=(\d{1,6}) temperature=([0-9.]{1,8})$',
    ).firstMatch(rest);
    if (legacy == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'cases': int.parse(legacy[1]!),
      'max_tokens': int.parse(legacy[2]!),
      'temperature': double.parse(legacy[3]!),
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_CASE') {
    final generic = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'(?:catalog=([A-Za-z0-9_.-]{1,120}) )?'
      r'case=([A-Za-z0-9_.-]{1,120}) '
      r'score=(\d{1,3})/(\d{1,3}) forbidden_hits=(\d{1,3}) '
      r'first_content_ms=(\d{1,12}) total_ms=(\d{1,12}) '
      r'prefill_ms=(-?\d{1,12}) '
      r'reported_tokens=(\d{1,12}) decode_tokens_s=([0-9.]{1,16}) '
      r'gpu_layers=(-?\d{1,6}) '
      r'(?:n_ctx=(-?\d{1,6}) )?'
      r'n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}) '
      r'pressure=(unknown|normal|high|critical)->(unknown|normal|high|critical) '
      r'start_available_bytes=(-?\d{1,15}) end_available_bytes=(-?\d{1,15}) '
      r'start_battery_temp_decic=(-?\d{1,6}) end_battery_temp_decic=(-?\d{1,6}) '
      r'session=(cold|warm|unknown)->(kept|released|unknown)$',
    ).firstMatch(rest);
    if (generic != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'model': generic[1]!,
        if (generic[2] != null) 'catalog': generic[2]!,
        'case': generic[3]!,
        'score': int.parse(generic[4]!),
        'max_score': int.parse(generic[5]!),
        'forbidden_hits': int.parse(generic[6]!),
        'first_content_ms': int.parse(generic[7]!),
        'total_ms': int.parse(generic[8]!),
        'prefill_ms': int.parse(generic[9]!),
        'reported_tokens': int.parse(generic[10]!),
        'decode_tokens_s': double.parse(generic[11]!),
        'gpu_layers': int.parse(generic[12]!),
        if (generic[13] != null) 'n_ctx': int.parse(generic[13]!),
        'n_batch': int.parse(generic[14]!),
        'n_ubatch': int.parse(generic[15]!),
        'start_pressure': generic[16]!,
        'end_pressure': generic[17]!,
        'start_available_bytes': int.parse(generic[18]!),
        'end_available_bytes': int.parse(generic[19]!),
        'start_battery_temp_decic': int.parse(generic[20]!),
        'end_battery_temp_decic': int.parse(generic[21]!),
        'session_start': generic[22]!,
        'session_end': generic[23]!,
      });
    }

    final current = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'case=(sdd_typo_first|vulkan_fact|ram_fact|arithmetic|ssd_direct|'
      r'sdd_repeat_empty|sdd_after_history|ssd_hdd_followup) '
      r'score=(\d{1,3})/(\d{1,3}) forbidden_hits=(\d{1,3}) '
      r'first_content_ms=(\d{1,12}) total_ms=(\d{1,12}) '
      r'prefill_ms=(-?\d{1,12}) '
      r'reported_tokens=(\d{1,12}) decode_tokens_s=([0-9.]{1,16}) '
      r'gpu_layers=(-?\d{1,6}) n_batch=(-?\d{1,6}) n_ubatch=(-?\d{1,6}) '
      r'pressure=(unknown|normal|high|critical)->(unknown|normal|high|critical) '
      r'start_available_bytes=(-?\d{1,15}) end_available_bytes=(-?\d{1,15}) '
      r'start_battery_temp_decic=(-?\d{1,6}) end_battery_temp_decic=(-?\d{1,6}) '
      r'session=(cold|warm|unknown)->(kept|released|unknown)$',
    ).firstMatch(rest);
    if (current != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'model': current[1]!,
        'case': current[2]!,
        'score': int.parse(current[3]!),
        'max_score': int.parse(current[4]!),
        'forbidden_hits': int.parse(current[5]!),
        'first_content_ms': int.parse(current[6]!),
        'total_ms': int.parse(current[7]!),
        'prefill_ms': int.parse(current[8]!),
        'reported_tokens': int.parse(current[9]!),
        'decode_tokens_s': double.parse(current[10]!),
        'gpu_layers': int.parse(current[11]!),
        'n_batch': int.parse(current[12]!),
        'n_ubatch': int.parse(current[13]!),
        'start_pressure': current[14]!,
        'end_pressure': current[15]!,
        'start_available_bytes': int.parse(current[16]!),
        'end_available_bytes': int.parse(current[17]!),
        'start_battery_temp_decic': int.parse(current[18]!),
        'end_battery_temp_decic': int.parse(current[19]!),
        'session_start': current[20]!,
        'session_end': current[21]!,
      });
    }

    final legacy = RegExp(
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
    if (legacy == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': legacy[1]!,
      'case': legacy[2]!,
      'score': int.parse(legacy[3]!),
      'max_score': int.parse(legacy[4]!),
      'forbidden_hits': int.parse(legacy[5]!),
      'first_content_ms': int.parse(legacy[6]!),
      'total_ms': int.parse(legacy[7]!),
      'reported_tokens': int.parse(legacy[8]!),
      'decode_tokens_s': double.parse(legacy[9]!),
      'gpu_layers': int.parse(legacy[10]!),
      'n_batch': int.parse(legacy[11]!),
      'n_ubatch': int.parse(legacy[12]!),
      'start_pressure': legacy[13]!,
      'end_pressure': legacy[14]!,
      if (legacy[15] != null)
        'start_available_bytes': int.parse(legacy[15]!),
      if (legacy[16] != null)
        'end_available_bytes': int.parse(legacy[16]!),
      if (legacy[17] != null) 'session_start': legacy[17]!,
      if (legacy[18] != null) 'session_end': legacy[18]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_MODEL_END') {
    final generic = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'(?:catalog=([A-Za-z0-9_.-]{1,120}) )?'
      r'quality=(\d{1,3})/(\d{1,3}) '
      r'avg_first_content_ms=([0-9.]{1,16}) '
      r'avg_total_ms=([0-9.]{1,16}) '
      r'avg_prefill_ms=([0-9.]{1,16}) '
      r'avg_decode_tokens_s=([0-9.]{1,16}) '
      r'max_battery_temp_c=(na|[0-9.]{1,16}) '
      r'battery_temp_delta_c=(na|-?[0-9.]{1,16}) '
      r'sdd_repeat_consistent=(true|false|na)$',
    ).firstMatch(rest);
    if (generic != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'model': generic[1]!,
        if (generic[2] != null) 'catalog': generic[2]!,
        'score': int.parse(generic[3]!),
        'max_score': int.parse(generic[4]!),
        'avg_first_content_ms': double.parse(generic[5]!),
        'avg_total_ms': double.parse(generic[6]!),
        'avg_prefill_ms': double.parse(generic[7]!),
        'avg_decode_tokens_s': double.parse(generic[8]!),
        if (generic[9] != 'na')
          'max_battery_temp_c': double.parse(generic[9]!),
        if (generic[10] != 'na')
          'battery_temp_delta_c': double.parse(generic[10]!),
        'sdd_repeat_consistent': generic[11]!,
      });
    }

    final current = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'quality=(\d{1,3})/(\d{1,3}) '
      r'avg_first_content_ms=([0-9.]{1,16}) '
      r'avg_total_ms=([0-9.]{1,16}) '
      r'avg_prefill_ms=([0-9.]{1,16}) '
      r'avg_decode_tokens_s=([0-9.]{1,16}) '
      r'max_battery_temp_c=(na|[0-9.]{1,16}) '
      r'battery_temp_delta_c=(na|-?[0-9.]{1,16}) '
      r'sdd_repeat_consistent=(true|false|na)$',
    ).firstMatch(rest);
    if (current != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'model': current[1]!,
        'score': int.parse(current[2]!),
        'max_score': int.parse(current[3]!),
        'avg_first_content_ms': double.parse(current[4]!),
        'avg_total_ms': double.parse(current[5]!),
        'avg_prefill_ms': double.parse(current[6]!),
        'avg_decode_tokens_s': double.parse(current[7]!),
        if (current[8] != 'na')
          'max_battery_temp_c': double.parse(current[8]!),
        if (current[9] != 'na')
          'battery_temp_delta_c': double.parse(current[9]!),
        'sdd_repeat_consistent': current[10]!,
      });
    }

    final legacy = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'quality=(\d{1,3})/(\d{1,3}) '
      r'avg_first_content_ms=([0-9.]{1,16}) '
      r'avg_total_ms=([0-9.]{1,16}) '
      r'avg_decode_tokens_s=([0-9.]{1,16})'
      r'(?: sdd_repeat_consistent=(true|false|na))?$',
    ).firstMatch(rest);
    if (legacy == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': legacy[1]!,
      'score': int.parse(legacy[2]!),
      'max_score': int.parse(legacy[3]!),
      'avg_first_content_ms': double.parse(legacy[4]!),
      'avg_total_ms': double.parse(legacy[5]!),
      'avg_decode_tokens_s': double.parse(legacy[6]!),
      if (legacy[7] != null) 'sdd_repeat_consistent': legacy[7]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_DUPLICATE_SKIPPED') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'catalog=([A-Za-z0-9_.-]{1,120}) '
      r'reason=(same_physical_file)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'catalog': m[2]!,
      'reason': m[3]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_PREFLIGHT') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'model_bytes=(\d{1,15}) '
      r'required_available_bytes=(\d{1,15}) '
      r'available_bytes=(-?\d{1,15}) '
      r'total_bytes=(-?\d{1,15}) '
      r'pressure=(unknown|normal|high|critical)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'model_bytes': int.parse(m[2]!),
      'required_available_bytes': int.parse(m[3]!),
      'available_bytes': int.parse(m[4]!),
      'total_bytes': int.parse(m[5]!),
      'pressure': m[6]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_REASONING_POLICY') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'reasoning_aware=(true|false) '
      r'max_tokens=(\d{1,6}) '
      r'final_answer=(true|false)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'reasoning_aware': m[2] == 'true',
      'max_tokens': int.parse(m[3]!),
      'final_answer': m[4] == 'true',
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_MODEL_SKIPPED') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'case=([A-Za-z0-9_.-]{1,120}) '
      r'reason=(critical_memory|insufficient_memory)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'case': m[2]!,
      'reason': m[3]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_THERMAL_GATE') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'state=(ready|cooldown|stop) '
      r'sample=(\d{1,3})/(\d{1,3}) '
      r'battery_temp_decic=(-?\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'state': m[2]!,
      'sample': int.parse(m[3]!),
      'max_samples': int.parse(m[4]!),
      'battery_temp_decic': int.parse(m[5]!),
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_THERMAL_STOP') {
    final m = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'reason=(temperature_cutoff|cooldown_timeout)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'reason': m[2]!,
    });
  }

  if (event == 'LOCAL_MODEL_BENCH_END') {
    final m = RegExp(
      r'^models=(\d{1,3})(?: failures=(\d{1,3}))?'
      r'(?: skips=(\d{1,3}))? '
      r'status=(success|failed|partial|skipped)$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'models': int.parse(m[1]!),
      if (m[2] != null) 'failures': int.parse(m[2]!),
      if (m[3] != null) 'skips': int.parse(m[3]!),
      'status': m[4]!,
    });
  }

  if (event == 'LOCAL_VULKAN_SWEEP_BEGIN') {
    final m = RegExp(
      r'^profiles=0,10,99 models=(\d{1,2}) repetitions=(\d{1,2})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'models': int.parse(m[1]!),
      'repetitions': int.parse(m[2]!),
    });
  }

  if (event == 'LOCAL_VULKAN_SWEEP_CASE') {
    final generic = RegExp(
      r'^model=([A-Za-z0-9_.-]{1,120}) '
      r'(?:catalog=([A-Za-z0-9_.-]{1,120}) )?'
      r'requested_gpu_layers=(0|10|99) '
      r'observed_gpu_layers=(-?\d{1,6}) '
      r'repetition=(1|2) '
      r'first_content_ms=(\d{1,12}) '
      r'prefill_ms=(-?\d{1,12}) '
      r'total_ms=(\d{1,12}) '
      r'reported_tokens=(\d{1,12}) '
      r'decode_tokens_s=([0-9.]{1,16}) '
      r'pressure=(unknown|normal|high|critical)->(unknown|normal|high|critical) '
      r'start_available_bytes=(-?\d{1,15}) end_available_bytes=(-?\d{1,15}) '
      r'start_battery_temp_decic=(-?\d{1,6}) end_battery_temp_decic=(-?\d{1,6})$',
    ).firstMatch(rest);
    if (generic != null) {
      return jsonEncode(<String, Object>{
        'time': time,
        'event': event,
        'model': generic[1]!,
        if (generic[2] != null) 'catalog': generic[2]!,
        'requested_gpu_layers': int.parse(generic[3]!),
        'observed_gpu_layers': int.parse(generic[4]!),
        'repetition': int.parse(generic[5]!),
        'first_content_ms': int.parse(generic[6]!),
        'prefill_ms': int.parse(generic[7]!),
        'total_ms': int.parse(generic[8]!),
        'reported_tokens': int.parse(generic[9]!),
        'decode_tokens_s': double.parse(generic[10]!),
        'start_pressure': generic[11]!,
        'end_pressure': generic[12]!,
        'start_available_bytes': int.parse(generic[13]!),
        'end_available_bytes': int.parse(generic[14]!),
        'start_battery_temp_decic': int.parse(generic[15]!),
        'end_battery_temp_decic': int.parse(generic[16]!),
      });
    }

    final m = RegExp(
      r'^model=(phi3_5_mini|nemotron3_nano_4b) '
      r'requested_gpu_layers=(0|10|99) '
      r'observed_gpu_layers=(-?\d{1,6}) '
      r'repetition=(1|2) '
      r'first_content_ms=(\d{1,12}) '
      r'prefill_ms=(-?\d{1,12}) '
      r'total_ms=(\d{1,12}) '
      r'reported_tokens=(\d{1,12}) '
      r'decode_tokens_s=([0-9.]{1,16}) '
      r'pressure=(unknown|normal|high|critical)->(unknown|normal|high|critical) '
      r'start_available_bytes=(-?\d{1,15}) end_available_bytes=(-?\d{1,15}) '
      r'start_battery_temp_decic=(-?\d{1,6}) end_battery_temp_decic=(-?\d{1,6})$',
    ).firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'model': m[1]!,
      'requested_gpu_layers': int.parse(m[2]!),
      'observed_gpu_layers': int.parse(m[3]!),
      'repetition': int.parse(m[4]!),
      'first_content_ms': int.parse(m[5]!),
      'prefill_ms': int.parse(m[6]!),
      'total_ms': int.parse(m[7]!),
      'reported_tokens': int.parse(m[8]!),
      'decode_tokens_s': double.parse(m[9]!),
      'start_pressure': m[10]!,
      'end_pressure': m[11]!,
      'start_available_bytes': int.parse(m[12]!),
      'end_available_bytes': int.parse(m[13]!),
      'start_battery_temp_decic': int.parse(m[14]!),
      'end_battery_temp_decic': int.parse(m[15]!),
    });
  }

  if (event == 'LOCAL_VULKAN_SWEEP_END') {
    final m = RegExp(r'^samples=(\d{1,3}) status=(success|failed)$')
        .firstMatch(rest);
    if (m == null) return null;
    return jsonEncode(<String, Object>{
      'time': time,
      'event': event,
      'samples': int.parse(m[1]!),
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
