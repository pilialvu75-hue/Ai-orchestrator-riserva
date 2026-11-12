import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_preview_policy.dart';

void main() {
  test('passive window selection retains its observed screenshot', () {
    expect(
      ComputerUsePreviewPolicy.shouldRefreshAfterAction('select_window_at'),
      isFalse,
    );
  });

  test('clicking or typing refreshes after the selected target gets focus', () {
    for (final action in <String>[
      'click',
      'type_text',
      'press_key',
      'open_app',
      'observe',
    ]) {
      expect(
        ComputerUsePreviewPolicy.shouldRefreshAfterAction(action),
        isTrue,
        reason: 'The preview should refresh after $action.',
      );
    }
  });
}
