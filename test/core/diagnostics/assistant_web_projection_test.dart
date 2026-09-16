import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const time = '[2026-09-16T18:08:24.217460]';

  test('exports Cloud web-search attempt without session or query text', () {
    final line = publicLogProjection(
      '$time [ASSISTANT_WEB_ENRICH] session=private-session mode=cloud '
      'action=search query_chars=37',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-16T18:08:24.217460',
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': 'cloud',
        'decision': 'attempt',
        'reason': 'dispatch',
        'query_chars': 37,
      },
    );
    expect(line, isNot(contains('private-session')));
  });

  test('exports successful Web evidence size without result contents', () {
    final line = publicLogProjection(
      '$time [ASSISTANT_WEB_ENRICH] session=default mode=cloud '
      'status=success result_chars=1248',
    );

    expect(
      jsonDecode(line!),
      <String, dynamic>{
        'time': '2026-09-16T18:08:24.217460',
        'event': 'ASSISTANT_WEB_SEARCH',
        'mode': 'cloud',
        'decision': 'success',
        'reason': 'completed',
        'result_chars': 1248,
      },
    );
  });

  test('exports Hybrid unavailable and execution failures generically', () {
    final unavailable = publicLogProjection(
      '$time [ASSISTANT_WEB_ENRICH] session=default mode=hybrid '
      'status=unavailable reason=tool_unavailable '
      'action=continue_without_web',
    );
    final failed = publicLogProjection(
      '$time [ASSISTANT_WEB_ENRICH] session=default mode=hybrid '
      'status=failed error_type=SocketException '
      'action=continue_without_web',
    );

    expect(jsonDecode(unavailable!)['reason'], 'tool_unavailable');
    expect(jsonDecode(unavailable)['decision'], 'failure');
    expect(jsonDecode(failed!)['reason'], 'execution_error');
    expect(failed, isNot(contains('SocketException')));
  });

  test('rejects Web telemetry extended with arbitrary conversation data', () {
    expect(
      publicLogProjection(
        '$time [ASSISTANT_WEB_ENRICH] session=default mode=cloud '
        'action=search query_chars=37 query=private-conversation',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [ASSISTANT_WEB_ENRICH] session=default mode=cloud '
        'status=success result_chars=1248 result=private-web-text',
      ),
      isNull,
    );
  });

  test('rejects unknown modes and malformed failure payloads', () {
    expect(
      publicLogProjection(
        '$time [ASSISTANT_WEB_ENRICH] session=default mode=local '
        'action=search query_chars=10',
      ),
      isNull,
    );
    expect(
      publicLogProjection(
        '$time [ASSISTANT_WEB_ENRICH] session=default mode=cloud '
        'status=failed error_type=Socket Exception',
      ),
      isNull,
    );
  });
}
