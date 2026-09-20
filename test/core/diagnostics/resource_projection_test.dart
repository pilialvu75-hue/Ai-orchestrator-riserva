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
