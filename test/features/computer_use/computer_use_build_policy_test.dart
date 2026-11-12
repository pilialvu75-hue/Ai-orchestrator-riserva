import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_build_policy.dart';

void main() {
  const expected = bool.fromEnvironment(
    'AIVEXUS_EXPECT_COMPUTER_USE_QA_ENABLED',
    defaultValue: false,
  );
  test('Computer Use manual laboratory obeys explicit build-time opt-in', () {
    expect(
      ComputerUseLabBuildPolicy.enabled,
      expected,
      reason: 'Ordinary builds must not expose experimental desktop control.',
    );
  });
}
