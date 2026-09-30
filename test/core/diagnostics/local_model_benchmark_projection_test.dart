import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const time = '[2026-09-25T14:30:00.000000]';

  test('exports benchmark case metrics without response text', () {
    final line = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_CASE] '
      'model=phi3_5_mini case=vulkan_fact score=2/2 forbidden_hits=0 '
      'first_content_ms=13890 total_ms=24120 prefill_ms=4310 reported_tokens=112 '
      'decode_tokens_s=10.95 gpu_layers=33 n_batch=128 n_ubatch=32 '
      'pressure=normal->high '
      'start_available_bytes=1800000000 end_available_bytes=800000000 '
      'start_battery_temp_decic=351 end_battery_temp_decic=368 '
      'session=warm->released',
    );

    final decoded = jsonDecode(line!) as Map<String, dynamic>;
    expect(decoded['event'], 'LOCAL_MODEL_BENCH_CASE');
    expect(decoded['model'], 'phi3_5_mini');
    expect(decoded['case'], 'vulkan_fact');
    expect(decoded['score'], 2);
    expect(decoded['first_content_ms'], 13890);
    expect(decoded['prefill_ms'], 4310);
    expect(decoded['gpu_layers'], 33);
    expect(decoded['start_battery_temp_decic'], 351);
    expect(decoded['end_battery_temp_decic'], 368);
    expect(decoded['start_available_bytes'], 1800000000);
    expect(decoded['end_available_bytes'], 800000000);
    expect(decoded['session_start'], 'warm');
    expect(decoded['session_end'], 'released');
    expect(line, isNot(contains('response=')));
  });

  test('exports safe arbitrary model and case ids with catalogue identity', () {
    final line = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_CASE] '
      'model=qwen3_1_7b catalog=import_qwen3_1_7b_q4 '
      'case=quality_logic_deduction score=1/1 forbidden_hits=0 '
      'first_content_ms=321 total_ms=987 prefill_ms=120 reported_tokens=12 '
      'decode_tokens_s=18.5 gpu_layers=29 n_ctx=2048 n_batch=128 n_ubatch=32 '
      'pressure=normal->normal '
      'start_available_bytes=1800000000 end_available_bytes=1600000000 '
      'start_battery_temp_decic=351 end_battery_temp_decic=354 '
      'session=cold->kept',
    );

    final decoded = jsonDecode(line!) as Map<String, dynamic>;
    expect(decoded['model'], 'qwen3_1_7b');
    expect(decoded['catalog'], 'import_qwen3_1_7b_q4');
    expect(decoded['case'], 'quality_logic_deduction');
    expect(decoded['n_ctx'], 2048);
  });

  test('rejects unsafe benchmark identifiers', () {
    expect(
      publicLogProjection(
        '$time [LOCAL_MODEL_BENCH_CASE] '
        'model=private/model case=vulkan_fact score=2/2 forbidden_hits=0 '
        'first_content_ms=1 total_ms=2 prefill_ms=1 reported_tokens=3 '
        'decode_tokens_s=4.0 gpu_layers=5 n_ctx=2048 n_batch=6 n_ubatch=7 '
        'pressure=normal->normal '
        'start_available_bytes=1000 end_available_bytes=900 '
        'start_battery_temp_decic=300 end_battery_temp_decic=301 '
        'session=warm->kept',
      ),
      isNull,
    );
  });

  test('exports current benchmark begin list and partial completion', () {
    final begin = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_BEGIN] '
      'models=llama_1b,qwen3_1_7b '
      'catalogs=llama_1b,custom_qwen_q4 '
      'cases=8 max_tokens=96 temperature=0.5',
    );
    final end = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_END] '
      'models=1 failures=1 status=partial',
    );

    final decodedBegin = jsonDecode(begin!) as Map<String, dynamic>;
    expect(decodedBegin['models'], <dynamic>['llama_1b', 'qwen3_1_7b']);
    expect(
      decodedBegin['catalogs'],
      <dynamic>['llama_1b', 'custom_qwen_q4'],
    );

    final decodedEnd = jsonDecode(end!) as Map<String, dynamic>;
    expect(decodedEnd['models'], 1);
    expect(decodedEnd['failures'], 1);
    expect(decodedEnd['status'], 'partial');
  });

  test('exports structured benchmark safety decisions', () {
    final duplicate = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_DUPLICATE_SKIPPED] '
      'model=deepseek_r1_1_5b catalog=local_import_deepseek '
      'reason=same_physical_file',
    );
    final preflight = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_PREFLIGHT] '
      'model=deepseek_coder_6_7b_instruct '
      'model_bytes=4083016640 required_available_bytes=5444022186 '
      'available_bytes=1250000000 total_bytes=7575265280 pressure=high',
    );
    final reasoning = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_REASONING_POLICY] '
      'model=deepseek_r1_1_5b reasoning_aware=true '
      'max_tokens=768 final_answer=false '
      'completion=budget_exhausted reported_tokens=768',
    );

    final decodedDuplicate =
        jsonDecode(duplicate!) as Map<String, dynamic>;
    expect(decodedDuplicate['reason'], 'same_physical_file');
    expect(decodedDuplicate['catalog'], 'local_import_deepseek');

    final decodedPreflight =
        jsonDecode(preflight!) as Map<String, dynamic>;
    expect(decodedPreflight['model_bytes'], 4083016640);
    expect(decodedPreflight['required_available_bytes'], 5444022186);
    expect(decodedPreflight['available_bytes'], 1250000000);
    expect(decodedPreflight['pressure'], 'high');

    final decodedReasoning =
        jsonDecode(reasoning!) as Map<String, dynamic>;
    expect(decodedReasoning['reasoning_aware'], isTrue);
    expect(decodedReasoning['max_tokens'], 768);
    expect(decodedReasoning['final_answer'], isFalse);
    expect(decodedReasoning['completion'], 'budget_exhausted');
    expect(decodedReasoning['reported_tokens'], 768);
  });

  test('exports structured benchmark thermal gate without free text', () {
    final gate = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_THERMAL_GATE] '
      'model=qwen2_5_3b_instruct state=cooldown '
      'sample=4/36 battery_temp_decic=438',
    );
    final stop = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_THERMAL_STOP] '
      'model=qwen2_5_3b_instruct reason=cooldown_timeout',
    );

    final decodedGate = jsonDecode(gate!) as Map<String, dynamic>;
    expect(decodedGate['event'], 'LOCAL_MODEL_BENCH_THERMAL_GATE');
    expect(decodedGate['state'], 'cooldown');
    expect(decodedGate['sample'], 4);
    expect(decodedGate['max_samples'], 36);
    expect(decodedGate['battery_temp_decic'], 438);

    final decodedStop = jsonDecode(stop!) as Map<String, dynamic>;
    expect(decodedStop['event'], 'LOCAL_MODEL_BENCH_THERMAL_STOP');
    expect(decodedStop['reason'], 'cooldown_timeout');

    expect(
      publicLogProjection(
        '$time [LOCAL_MODEL_BENCH_THERMAL_STOP] '
        'model=qwen2_5_3b_instruct reason=testo libero',
      ),
      isNull,
    );
  });

  test('exports benchmark model summary and memory release safely', () {
    final summary = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_MODEL_END] '
      'model=nemotron3_nano_4b quality=9/11 '
      'avg_first_content_ms=9724 avg_total_ms=14058 '
      'avg_prefill_ms=4120 avg_decode_tokens_s=11.22 '
      'max_battery_temp_c=39.4 battery_temp_delta_c=2.1 '
      'sdd_repeat_consistent=true',
    );
    final release = publicLogProjection(
      '$time [POST_GENERATION_MEMORY_RELEASE] '
      'session=private-session native_session=4 modelId=nemotron3_nano_4b '
      'available_bytes=802762752 threshold_bytes=408944640 pressure=high',
    );

    final decodedSummary = jsonDecode(summary!) as Map<String, dynamic>;
    expect(decodedSummary['quality'], isNull);
    expect(decodedSummary['score'], 9);
    expect(decodedSummary['model'], 'nemotron3_nano_4b');
    expect(decodedSummary['avg_prefill_ms'], 4120);
    expect(decodedSummary['max_battery_temp_c'], 39.4);
    expect(decodedSummary['battery_temp_delta_c'], 2.1);
    expect(decodedSummary['sdd_repeat_consistent'], 'true');

    final decodedRelease = jsonDecode(release!) as Map<String, dynamic>;
    expect(decodedRelease['event'], 'POST_GENERATION_MEMORY_RELEASE');
    expect(decodedRelease['model'], 'nemotron3_nano_4b');
    expect(decodedRelease['pressure'], 'high');
    expect(release, isNot(contains('private-session')));
    expect(release, isNot(contains('native_session')));
  });

  test('exports Vulkan sweep metrics without private session data', () {
    final line = publicLogProjection(
      '$time [LOCAL_VULKAN_SWEEP_CASE] '
      'model=phi3_5_mini requested_gpu_layers=99 observed_gpu_layers=33 '
      'repetition=2 first_content_ms=12000 prefill_ms=4400 total_ms=17000 '
      'reported_tokens=50 decode_tokens_s=10.00 pressure=normal->high '
      'start_available_bytes=1800000000 end_available_bytes=900000000 '
      'start_battery_temp_decic=352 end_battery_temp_decic=381',
    );

    final decoded = jsonDecode(line!) as Map<String, dynamic>;
    expect(decoded['requested_gpu_layers'], 99);
    expect(decoded['observed_gpu_layers'], 33);
    expect(decoded['prefill_ms'], 4400);
    expect(decoded['end_battery_temp_decic'], 381);
    expect(line, isNot(contains('session=')));
  });

  test('keeps historical benchmark case grammar readable', () {
    final line = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_CASE] '
      'model=phi3_5_mini case=vulkan_fact score=2/2 forbidden_hits=0 '
      'first_content_ms=100 total_ms=200 reported_tokens=10 '
      'decode_tokens_s=100.0 gpu_layers=10 n_batch=128 n_ubatch=32 '
      'pressure=normal->normal session=warm->kept',
    );
    expect(line, isNotNull);
    final decoded = jsonDecode(line!) as Map<String, dynamic>;
    expect(decoded.containsKey('prefill_ms'), isFalse);
  });

  test('exports all current resource profile reasons', () {
    for (final reason in <String>[
      'pressure',
      'phi_conservative',
      'phi_gpu_conservative',
      'device_memory_budget',
      'device_memory_conservative',
      'device_gpu_conservative',
      'baseline',
    ]) {
      final line = publicLogProjection(
        '$time [RESOURCE_PROFILE] reason=$reason '
        'n_ctx=2048 n_batch=128 n_ubatch=32',
      );
      expect(line, isNotNull, reason: reason);
      expect(jsonDecode(line!)['reason'], reason);
    }
  });
}
