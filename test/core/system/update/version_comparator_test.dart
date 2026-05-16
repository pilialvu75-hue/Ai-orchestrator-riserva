import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';

void main() {
  const comparator = VersionComparator();

  test('compares all numeric segments including build revisions', () {
    expect(
      comparator.compare('v1.0.12.106', 'v1.0.12.105'),
      greaterThan(0),
    );
    expect(
      comparator.compare('1.0.13.1', '1.0.12.999'),
      greaterThan(0),
    );
    expect(comparator.compare('1.1.0', '1.0.99'), greaterThan(0));
    expect(comparator.compare('2.0.0', '1.999.999'), greaterThan(0));
  });

  test('treats build metadata as comparable numeric revision segments', () {
    expect(comparator.compare('1.0.12+106', '1.0.12+105'), greaterThan(0));
    expect(comparator.compare('1.0.12+105', '1.0.12.105'), 0);
  });

  test('pads missing numeric segments with zeroes', () {
    expect(comparator.compare('1.0.12', '1.0.12.0'), 0);
    expect(comparator.compare('1.0.12.1', '1.0.12'), greaterThan(0));
  });

  test('orders stable releases after prereleases for same numeric version', () {
    expect(comparator.compare('1.0.12', '1.0.12-beta'), greaterThan(0));
    expect(
      comparator.compare('1.0.12-beta.2', '1.0.12-beta.1'),
      greaterThan(0),
    );
    expect(
      comparator.compare('1.0.12-beta', '1.0.12-nightly'),
      greaterThan(0),
    );
  });

  test('treats malformed versions as unparsable', () {
    expect(comparator.parse(''), isNull);
    expect(comparator.parse('1.0'), isNull);
    expect(comparator.parse('v1..12.1'), isNull);
    expect(comparator.parse('foo'), isNull);
  });
}
