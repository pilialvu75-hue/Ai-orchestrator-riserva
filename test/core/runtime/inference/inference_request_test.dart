import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InferenceRequest copyWith', () {
    test('clones the original context list', () {
      final sourceContext = <String>['alpha'];
      final request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
        context: sourceContext,
      );

      final copy = request.copyWith();

      sourceContext.add('beta');

      expect(request.context, <String>['alpha', 'beta']);
      expect(copy.context, <String>['alpha']);
    });

    test('clones the replacement context list', () {
      final replacementContext = <String>['one'];
      final request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
      );

      final copy = request.copyWith(context: replacementContext);

      replacementContext.add('two');

      expect(copy.context, <String>['one']);
      expect(() => copy.context.add('three'), throwsUnsupportedError);
    });
  });
}
