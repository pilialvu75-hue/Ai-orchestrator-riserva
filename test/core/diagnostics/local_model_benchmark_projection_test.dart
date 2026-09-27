import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const time = '[2026-09-25T14:30:00.000000]';

  test('exports benchmark case metrics without response text', () {
    final line = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_CASE] '
      'model=phi3_5_mini case=vulkan_fact score=2/2 forbidden_hits=0 '
      'first_content_ms=13890 total_ms=24120 reported_tokens=112 '
      'decode_tokens_s=10.95 gpu_layers=33 n_batch=128 n_ubatch=32 '
      'pressure=normal->high '
      'start_available_bytes=1800000000 end_available_bytes=800000000 '
      'session=warm->released',
    );

    final decoded = jsonDecode(line!) as Map<String, dynamic>;
    expect(decoded['event'], 'LOCAL_MODEL_BENCH_CASE');
    expect(decoded['model'], 'phi3_5_mini');
    expect(decoded['case'], 'vulkan_fact');
    expect(decoded['score'], 2);
    expect(decoded['first_content_ms'], 13890);
    expect(decoded['gpu_layers'], 33);
    expect(decoded['start_available_bytes'], 1800000000);
    expect(decoded['end_available_bytes'], 800000000);
    expect(decoded['session_start'], 'warm');
    expect(decoded['session_end'], 'released');
    expect(line, isNot(contains('response=')));
  });

  test('rejects benchmark data for unknown model or case', () {
    expect(
      publicLogProjection(
        '$time [LOCAL_MODEL_BENCH_CASE] '
        'model=private_model case=vulkan_fact score=2/2 forbidden_hits=0 '
        'first_content_ms=1 total_ms=2 reported_tokens=3 '
        'decode_tokens_s=4.0 gpu_layers=5 n_batch=6 n_ubatch=7 '
        'pressure=normal->normal',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [LOCAL_MODEL_BENCH_CASE] '
        'model=phi3_5_mini case=private_case score=1/1 forbidden_hits=0 '
        'first_content_ms=1 total_ms=2 reported_tokens=3 '
        'decode_tokens_s=4.0 gpu_layers=5 n_batch=6 n_ubatch=7 '
        'pressure=normal->normal',
      ),
      isNull,
    );
  });

  test('exports benchmark model summary and memory release safely', () {
    final summary = publicLogProjection(
      '$time [LOCAL_MODEL_BENCH_MODEL_END] '
      'model=nemotron3_nano_4b quality=9/11 '
      'avg_first_content_ms=9724 avg_total_ms=14058 '
      'avg_decode_tokens_s=11.22 sdd_repeat_consistent=true',
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
    expect(decodedSummary['sdd_repeat_consistent'], 'true');

    final decodedRelease = jsonDecode(release!) as Map<String, dynamic>;
    expect(decodedRelease['event'], 'POST_GENERATION_MEMORY_RELEASE');
    expect(decodedRelease['model'], 'nemotron3_nano_4b');
    expect(decodedRelease['pressure'], 'high');
    expect(release, isNot(contains('private-session')));
    expect(release, isNot(contains('native_session')));
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
