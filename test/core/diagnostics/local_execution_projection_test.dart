import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const prefix = '[2026-09-14T12:53:42.288] [LOCAL_EXECUTION_CONFIG] ';

  test('exports the exact CPU comparison configuration', () {
    final result = publicLogProjection(
      '${prefix}mode=cpu_baseline gpu_layers=0 n_ctx=4096 n_batch=512',
    );
    expect(jsonDecode(result!), <String, Object>{
      'time': '2026-09-14T12:53:42.288',
      'event': 'LOCAL_EXECUTION_CONFIG',
      'mode': 'cpu_baseline',
      'gpu_layers': 0,
      'n_ctx': 4096,
      'n_batch': 512,
    });
  });

  test('rejects extra payload and incorrectly labelled GPU execution', () {
    for (final payload in <String>[
      'mode=cpu_baseline gpu_layers=0 n_ctx=4096 n_batch=512 path=/private',
      'mode=cpu_baseline gpu_layers=10 n_ctx=4096 n_batch=512',
      'mode=cpu_baseline gpu_layers=0 n_ctx=unknown n_batch=512',
    ]) {
      expect(publicLogProjection('$prefix$payload'), isNull);
    }
  });
}
