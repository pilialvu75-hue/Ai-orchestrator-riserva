import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/presentation/chat/view_models/chat_appearance_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('panel close clears legacy appearance Debug Lab visibility', () {
    final controller = DebugLabController.instance;
    controller.close();

    final viewModel = ChatAppearanceViewModel();
    addTearDown(viewModel.dispose);

    for (var i = 0; i < 7; i++) {
      viewModel.handleSecretPatternClick();
    }

    expect(viewModel.debugLabOpen, isTrue);
    expect(controller.isVisible, isFalse);

    // Regression: the overlay X calls DebugLabController.close(). Previously
    // this returned early because controller.isVisible was already false,
    // leaving ChatAppearanceViewModel.debugLabOpen=true and the panel visible.
    controller.close();

    expect(viewModel.debugLabOpen, isFalse);
  });
}
