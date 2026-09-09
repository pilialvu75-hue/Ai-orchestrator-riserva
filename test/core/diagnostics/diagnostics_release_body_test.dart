import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/diagnostics/diagnostics_release_body.dart';

void main() {
  test('preserves device header and latest events within a bounded body', () {
    final batch = 'schema=1 device=test\n${List.generate(2000, (i) => '{"event":"TEST","index":$i,"padding":"abcdefghijklmnop"}').join('\n')}\n';
    final body = diagnosticsReleaseBody(batch);
    expect(body, contains('schema=1 device=test'));
    expect(body, contains('"index":1999'));
    expect(body, isNot(contains('"index":0,')));
    expect(body.length, lessThan(60000));
  });

  test('renders log text as indented code and handles empty batches', () {
    expect(diagnosticsReleaseBody('header\n```\n'), contains('    ```'));
    expect(diagnosticsReleaseBody(''), contains('ultimo lotto'));
  });
}
