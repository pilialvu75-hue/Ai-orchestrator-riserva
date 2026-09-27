import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CapturingProvider implements RuntimeInferenceProvider {
  _CapturingProvider({this.cancelInternally = false});

  final bool cancelInternally;
  CancellationToken? lastToken;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    lastToken = cancellationToken;
    if (cancelInternally) {
      cancellationToken.cancel();
    }
    return const Stream.empty();
  }
}

void main() {
  group('WorkshopInferenceGateway cancellation isolation', () {
    test('runtime cancellation does not cancel the caller task token', () {
      final callerToken = CancellationToken();
      final provider = _CapturingProvider(cancelInternally: true);
      final gateway = WorkshopInferenceGateway(provider: provider);

      gateway.stream(
        prompt: 'Run the bounded Workshop stage.',
        cancellationToken: callerToken,
      );

      expect(provider.lastToken, isNotNull);
      expect(provider.lastToken, isNot(same(callerToken)));
      expect(provider.lastToken!.isCancelled, isTrue);
      expect(callerToken.isCancelled, isFalse);
    });

    test('caller cancellation still propagates to the runtime token', () {
      final callerToken = CancellationToken();
      final provider = _CapturingProvider();
      final gateway = WorkshopInferenceGateway(provider: provider);

      gateway.stream(
        prompt: 'Run the bounded Workshop stage.',
        cancellationToken: callerToken,
      );
      final runtimeToken = provider.lastToken;

      expect(runtimeToken, isNotNull);
      expect(runtimeToken, isNot(same(callerToken)));
      expect(runtimeToken!.isCancelled, isFalse);

      callerToken.cancel();

      expect(callerToken.isCancelled, isTrue);
      expect(runtimeToken.isCancelled, isTrue);
    });
  });
}
