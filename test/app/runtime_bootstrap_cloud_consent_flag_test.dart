import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app/runtime_bootstrap.dart';

void main() {
  test('HYBRID consent QA is compiled off unless explicitly requested', () {
    const expectEnabled =
        bool.fromEnvironment('AIVEXUS_EXPECT_HYBRID_QA_ENABLED',
            defaultValue: false);
    expect(RuntimeBootstrap.experimentalConsentGateEnabled, expectEnabled);
  });
}
