import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

void main() {
  setUp(() {
    RuntimeEventLog.instance.clear();
  });

  test('redacts quoted search query before retaining the event', () {
    const secret = 'meteo privato parigi domani';

    RuntimeEventLog.instance.emit(
      '[TOOL_EXECUTION_BEGIN] tool=web_search session=default '
      'query="$secret"',
    );

    final entry = RuntimeEventLog.instance.entries.single;

    expect(entry.message, isNot(contains(secret)));
    expect(entry.message, contains('query_chars=${secret.length}'));
    expect(entry.message, contains('tool=web_search'));
  });

  test('redacts every quoted query field in the same event', () {
    RuntimeEventLog.instance.emit(
      '[TOOL_INTERCEPTOR] query="first" retry_query="safe" query="second one"',
    );

    final message = RuntimeEventLog.instance.entries.single.message;

    expect(message, isNot(contains('query="first"')));
    expect(message, isNot(contains('query="second one"')));
    expect(message, contains('query_chars=5'));
    expect(message, contains('query_chars=10'));
    expect(message, contains('retry_query="safe"'));
  });

  test('leaves ordinary diagnostics and query_chars metadata unchanged', () {
    const message =
        '[WEBSEARCH_ENTER] query_chars=42 limit=5 status=starting';

    RuntimeEventLog.instance.emit(message);

    expect(RuntimeEventLog.instance.entries.single.message, message);
  });

  test('preserves tag and category after query redaction', () {
    RuntimeEventLog.instance.emit(
      '[WEBSEARCH_PROVIDER_SELECTED] query="secret" provider=duckduckgo_lite',
    );

    final entry = RuntimeEventLog.instance.entries.single;

    expect(entry.tag, 'WEBSEARCH_PROVIDER_SELECTED');
    expect(entry.category, RuntimeEventCategory.websearch);
  });
}
