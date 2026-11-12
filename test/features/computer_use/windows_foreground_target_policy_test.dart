import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

void main() {
  group('Windows Computer Use foreground targeting policy', () {
    test('accepts only the process launched for the smoke test', () {
      expect(
        WindowsComputerUseAdapter.isExpectedForegroundProcess(
          foregroundProcessId: 4201,
          hostProcessId: 100,
          launchedProcessId: 4201,
        ),
        isTrue,
      );
    });

    test('never accepts an unrelated foreground application after launch', () {
      expect(
        WindowsComputerUseAdapter.isExpectedForegroundProcess(
          foregroundProcessId: 555,
          hostProcessId: 100,
          launchedProcessId: 4201,
        ),
        isFalse,
      );
    });

    test('never accepts the Aivexus process or missing foreground PID', () {
      for (final foreground in <int>[0, 100, -1]) {
        expect(
          WindowsComputerUseAdapter.isExpectedForegroundProcess(
            foregroundProcessId: foreground,
            hostProcessId: 100,
            launchedProcessId: 4201,
          ),
          isFalse,
        );
      }
    });

    test('manual targeting works without a pending launched test app', () {
      expect(
        WindowsComputerUseAdapter.isExpectedForegroundProcess(
          foregroundProcessId: 700,
          hostProcessId: 100,
        ),
        isTrue,
      );
    });
  });
}
