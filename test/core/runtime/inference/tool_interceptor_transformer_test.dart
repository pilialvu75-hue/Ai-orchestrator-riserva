import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/tool_interceptor_transformer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolInterceptorTransformer', () {
    Stream<InferenceResponse> transform(
      Iterable<InferenceResponse> responses,
    ) {
      return Stream<InferenceResponse>.fromIterable(responses)
          .transform(ToolInterceptorTransformer());
    }

    test('drops incomplete search fragments at stream completion', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, isEmpty);
    });

    test('drops an incomplete search opening tag at stream completion',
        () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello <sea',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Hello ');
      expect(chunks.single.runtimeNotice, isNull);
      expect(chunks.single.model, 'test-model');
    });

    test('emits a search notice for a complete search tag', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search>weather in rome</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, isEmpty);
      expect(chunks.single.runtimeNotice, 'search:weather in rome');
      expect(chunks.single.isFinal, isFalse);
      expect(chunks.single.terminalState, isNull);
    });

    test('emits normal text before the search notice', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'I will search for you. '
                '<search>weather in rome</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(2));

      expect(chunks[0].text, 'I will search for you. ');
      expect(chunks[0].runtimeNotice, isNull);
      expect(chunks[0].model, 'test-model');

      expect(chunks[1].text, isEmpty);
      expect(chunks[1].runtimeNotice, 'search:weather in rome');
      expect(chunks[1].isFinal, isFalse);
      expect(chunks[1].terminalState, isNull);
    });

    test('detects a search tag split across multiple chunks', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Searching <sea',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'rch>weather in rome',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: '</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(2));

      expect(chunks[0].text, 'Searching ');
      expect(chunks[0].runtimeNotice, isNull);
      expect(chunks[0].model, 'test-model');

      expect(chunks[1].text, isEmpty);
      expect(chunks[1].runtimeNotice, 'search:weather in rome');
      expect(chunks[1].isFinal, isFalse);
      expect(chunks[1].terminalState, isNull);
    });

    test('preserves normal text split around a partial search prefix',
        () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello <sea',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'rch>Paris weather</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(2));

      expect(chunks[0].text, 'Hello ');
      expect(chunks[0].runtimeNotice, isNull);
      expect(chunks[0].model, 'test-model');

      expect(chunks[1].text, isEmpty);
      expect(chunks[1].runtimeNotice, 'search:Paris weather');
      expect(chunks[1].isFinal, isFalse);
      expect(chunks[1].terminalState, isNull);
    });

    test('does not emit text after the closing search tag', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search>weather in rome</search>',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'this must not be emitted',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, isEmpty);
      expect(chunks.single.runtimeNotice, 'search:weather in rome');
    });

    test('trims the extracted search query', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search>  weather in rome  </search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.runtimeNotice, 'search:weather in rome');
    });

    test('forwards error responses immediately', () async {
      final errorResponse = InferenceResponse.error(
        'test error',
      );

      final chunks = await transform(
        <InferenceResponse>[
          errorResponse,
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, same(errorResponse));
      expect(chunks.single.isError, isTrue);
      expect(chunks.single.isFinal, isTrue);
      expect(
        chunks.single.terminalState,
        InferenceTerminalState.failed,
      );
      expect(chunks.single.errorMessage, 'test error');
    });

    test('forwards empty responses unchanged', () async {
      final emptyResponse = InferenceResponse.token(
        text: '',
        model: 'test-model',
      );

      final chunks = await transform(
        <InferenceResponse>[
          emptyResponse,
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, same(emptyResponse));
    });

    test('forwards normal text at stream completion', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello world',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Hello world');
      expect(chunks.single.runtimeNotice, isNull);
      expect(chunks.single.model, 'test-model');
    });

    test('preserves text before an incomplete search tag at completion',
        () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello <search>weather',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Hello ');
      expect(chunks.single.runtimeNotice, isNull);
      expect(chunks.single.model, 'test-model');
    });

    test('does not create a search notice without a closing tag', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search>weather in rome',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(
        chunks.where((response) => response.runtimeNotice != null),
        isEmpty,
      );
    });

    test('preserves the model for separately emitted normal tokens',
        () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello ',
            model: 'model-a',
          ),
          InferenceResponse.token(
            text: 'world',
            model: 'model-a',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(2));

      expect(chunks[0].text, 'Hello ');
      expect(chunks[0].model, 'model-a');

      expect(chunks[1].text, 'world');
      expect(chunks[1].model, 'model-a');
    });

    test('uses the model active when buffered text is emitted', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello <',
            model: 'model-a',
          ),
          InferenceResponse.token(
            text: 'search>weather</search>',
            model: 'model-b',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(2));

      // "Hello " is flushed immediately from the first chunk.
      // Only "<" remains buffered because it may start "<search>".
      expect(chunks[0].text, 'Hello ');
      expect(chunks[0].runtimeNotice, isNull);
      expect(chunks[0].model, 'model-a');

      expect(chunks[1].text, isEmpty);
      expect(chunks[1].runtimeNotice, 'search:weather');
      expect(chunks[1].isFinal, isFalse);
      expect(chunks[1].terminalState, isNull);
    });

    test('handles a search tag with an empty query', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search></search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, isEmpty);
      expect(chunks.single.runtimeNotice, 'search:');
    });

    test('does not emit the opening search tag as normal text', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Before <search>',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'query</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      final normalText = chunks
          .where((response) => response.runtimeNotice == null)
          .map((response) => response.text)
          .join();

      expect(normalText, 'Before ');
      expect(
        chunks.where(
          (response) => response.runtimeNotice == 'search:query',
        ),
        hasLength(1),
      );
    });

    test('does not treat an unrelated closing tag as a search', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello </search> world',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Hello </search> world');
      expect(chunks.single.runtimeNotice, isNull);
    });

    test('handles search opening tag split at every character boundary',
        () async {
      const input = '<search>weather</search>';

      final responses = <InferenceResponse>[];

      for (var i = 0; i < input.length; i++) {
        responses.add(
          InferenceResponse.token(
            text: input.substring(i, i + 1),
            model: 'test-model',
          ),
        );
      }

      final chunks = await transform(responses).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, isEmpty);
      expect(chunks.single.runtimeNotice, 'search:weather');
    });

    test('forwards text preceding a search tag exactly once', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'One ',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'two ',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'three <sea',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'rch>query</search>',
            model: 'test-model',
          ),
        ],
      ).toList();

      final normalText = chunks
          .where((response) => response.runtimeNotice == null)
          .map((response) => response.text)
          .join();

      expect(normalText, 'One two three ');

      expect(
        chunks.where(
          (response) => response.runtimeNotice == 'search:query',
        ),
        hasLength(1),
      );
    });

    test('does not emit residual text after search detection', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Before ',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: '<search>query</search>After',
            model: 'test-model',
          ),
        ],
      ).toList();

      final normalText = chunks
          .where((response) => response.runtimeNotice == null)
          .map((response) => response.text)
          .join();

      expect(normalText, 'Before ');
      expect(
        chunks.where(
          (response) => response.runtimeNotice == 'search:query',
        ),
        hasLength(1),
      );
    });

    test('detects a closing search tag split across chunks', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: '<search>weather</sea',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'rch>',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.text, isEmpty);
      expect(chunks.single.runtimeNotice, 'search:weather');
    });

    test('forwards normal text without duplication', () async {
      final chunks = await transform(
        <InferenceResponse>[
          InferenceResponse.token(
            text: 'Hello ',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'beautiful ',
            model: 'test-model',
          ),
          InferenceResponse.token(
            text: 'world',
            model: 'test-model',
          ),
        ],
      ).toList();

      expect(chunks, hasLength(3));

      final text = chunks
          .where((response) => response.runtimeNotice == null)
          .map((response) => response.text)
          .join();

      expect(text, 'Hello beautiful world');
    });

    test('forwards empty responses unchanged between normal chunks',
        () async {
      final first = InferenceResponse.token(
        text: 'Hello ',
        model: 'test-model',
      );

      final empty = InferenceResponse.token(
        text: '',
        model: 'test-model',
      );

      final last = InferenceResponse.token(
        text: 'world',
        model: 'test-model',
      );

      final chunks = await transform(
        <InferenceResponse>[
          first,
          empty,
          last,
        ],
      ).toList();

      expect(chunks, hasLength(3));

      // Normal tokens are reconstructed by the transformer.
      expect(chunks[0].text, 'Hello ');
      expect(chunks[0].runtimeNotice, isNull);
      expect(chunks[0].model, 'test-model');

      // Empty responses are forwarded exactly as received.
      expect(chunks[1], same(empty));

      expect(chunks[2].text, 'world');
      expect(chunks[2].runtimeNotice, isNull);
      expect(chunks[2].model, 'test-model');
    });

    test('does not emit an error after a terminal search notice', () async {
      final controller = StreamController<InferenceResponse>();

      final future = controller.stream
          .transform(ToolInterceptorTransformer())
          .toList();

      controller.add(
        InferenceResponse.token(
          text: '<search>weather</search>',
          model: 'test-model',
        ),
      );

      controller.add(
        InferenceResponse.error('must not be forwarded'),
      );

      await controller.close();

      final chunks = await future;

      expect(chunks, hasLength(1));
      expect(chunks.single.runtimeNotice, 'search:weather');
      expect(chunks.single.isError, isFalse);
    });
  });
}
