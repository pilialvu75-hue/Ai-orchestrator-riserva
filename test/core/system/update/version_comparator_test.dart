import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';

void main() {
  const comparator = VersionComparator();

  test('compares semantic versions correctly', () {
    expect(comparator.compare('1.0.8', '1.0.7'), greaterThan(0));
    expect(comparator.compare('1.1.0', '1.0.9'), greaterThan(0));
    expect(comparator.compare('1.0.7', '1.0.8'), lessThan(0));
  });

  test('orders release stability for same numeric version', () {
    expect(comparator.compare('1.0.8', '1.0.8-beta'), greaterThan(0));
    expect(comparator.compare('1.0.8-beta', '1.0.8-nightly'), greaterThan(0));
    expect(comparator.compare('1.0.8-nightly', '1.0.8-dev'), greaterThan(0));
  });

  test('compares channel build numbers', () {
    expect(comparator.compare('1.0.8-beta.2', '1.0.8-beta.1'), greaterThan(0));
  });
}
