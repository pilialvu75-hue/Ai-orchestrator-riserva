import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/tool_interceptor_transformer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolInterceptorTransformer', () {
    test('drops incomplete search fragments at stream completion', () async {
      final chunks = await Stream<InferenceResponse>.fromIterable(
        <InferenceResponse>[
          InferenceResponse.token(text: '<'),
        ],
      ).transform(ToolInterceptorTransformer()).toList();

      expect(chunks, isEmpty);
    });

    test('emits a notice for a complete search tag', () async {
      final chunks = await Stream<InferenceResponse>.fromIterable(
        <InferenceResponse>[
          InferenceResponse.token(text: '<search>weather in rome</search>'),
        ],
      ).transform(ToolInterceptorTransformer()).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.runtimeNotice, isNotNull);
      expect(chunks.single.text, isEmpty);
    });
  });
}
