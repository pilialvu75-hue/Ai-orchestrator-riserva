import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/presentation/chat/view_models/chat_appearance_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metrics menu opens Debug Lab independently of secret gestures', () {
    final controller = DebugLabController.instance;
    controller.close();
    addTearDown(controller.close);
    var notifications = 0;
    void listener() => notifications++;
    controller.addListener(listener);
    addTearDown(() => controller.removeListener(listener));

    controller.openFromMetricsMenu();
    expect(controller.isVisible, isTrue);
    expect(notifications, 1);
    controller.openFromMetricsMenu();
    expect(notifications, 1);
    controller.close();
    expect(controller.isVisible, isFalse);
    expect(notifications, 2);
  });

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
