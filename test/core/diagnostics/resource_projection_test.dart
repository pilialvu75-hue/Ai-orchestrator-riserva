import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const prefix = '[2026-09-20T14:45:17.000] [RESOURCE_SAMPLE] ';
  const payload =
      'available_bytes=123 rss_bytes=456 native_heap_bytes=-1 critical=false phase=loading gpu_layers=0 decode_calls=0';
  test('resource diagnostics preserve numeric facts without prompt data', () {
    final json = jsonDecode(publicLogProjection('$prefix$payload')!);
    expect(json['gpu_layers'], 0);
    expect(json['native_heap_bytes'], -1);
    expect(publicLogProjection('$prefix$payload prompt=private'), isNull);
    expect(
      publicLogProjection(
        '$prefix${payload.replaceFirst('phase=loading', 'phase=private')}',
      ),
      isNull,
    );
  });
  test('extended samples export thresholds pressure and native profile safely',
      () {
    const suffix =
        ' total_bytes=8000 threshold_bytes=500 pressure=high low_memory=false trim_level=10 n_ctx=2048 n_batch=128 n_ubatch=32';
    final exported = jsonDecode(publicLogProjection('$prefix$payload$suffix')!);
    expect(exported['total_bytes'], 8000);
    expect(exported['threshold_bytes'], 500);
    expect(exported['pressure'], 'high');
    expect(exported['n_ubatch'], 32);
    expect(
        publicLogProjection('$prefix$payload$suffix prompt=private'), isNull);
    expect(
        publicLogProjection(
            '$prefix$payload${suffix.replaceFirst('pressure=high', 'pressure=secret')}'),
        isNull);
  });
  test('guard export uses closed action vocabulary', () {
    const p = '[2026-09-20T14:45:17.000] [RESOURCE_GUARD] ';
    expect(
      publicLogProjection('${p}action=cancel reason=critical_memory'),
      isNotNull,
    );
    expect(
      publicLogProjection('${p}action=upload reason=critical_memory'),
      isNull,
    );
  });
}
