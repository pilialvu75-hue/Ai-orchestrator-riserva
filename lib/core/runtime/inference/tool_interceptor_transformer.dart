import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

class ToolInterceptorTransformer extends StreamTransformerBase<InferenceResponse, InferenceResponse> {
  static const String _searchTagStart = '<search>';
  static const String _searchTagEnd = '</search>';

  @override
  Stream<InferenceResponse> bind(Stream<InferenceResponse> stream) {
    late StreamController<InferenceResponse> controller;
    StreamSubscription<InferenceResponse>? subscription;

    controller = StreamController<InferenceResponse>(
      onListen: () {
        final buffer = StringBuffer();
        var searchMode = false;

        subscription = stream.listen(
          (response) {
            if (response.isError) {
              controller.add(response);
              return;
            }

            final textChunk = response.text;
            if (textChunk.isEmpty) {
              if (response.runtimeNotice != null) {
                controller.add(response);
              }
              return;
            }

            buffer.write(textChunk);
            final currentText = buffer.toString();
            final match = RegExp(r'<search>(.*?)</search>', dotAll: true).firstMatch(currentText);

            if (match != null) {
              final query = match.group(1)?.trim() ?? '';
              RuntimeEventLog.instance.emit(
                '[TOOL_INTERCEPTOR] target=search status=extracted query="$query"',
              );
              controller.add(
                InferenceResponse.notice("Sto cercando su Internet: '$query'"),
              );
              buffer.clear();
              searchMode = false;
              return;
            }

            if (currentText.contains(_searchTagStart)) {
              searchMode = true;
              return;
            }

            if (searchMode || _hasPartialSearchTag(currentText)) {
              searchMode = true;
              return;
            }

            controller.add(
              InferenceResponse.token(
                text: currentText,
                model: response.model,
              ),
            );
            buffer.clear();
          },
          onError: controller.addError,
          onDone: () {
            final pendingText = buffer.toString();
            final shouldDiscardPending =
                pendingText.contains(_searchTagStart) || _hasPartialSearchTag(pendingText);
            if (pendingText.isNotEmpty && !shouldDiscardPending && !controller.isClosed) {
              controller.add(
                InferenceResponse.token(
                  text: pendingText,
                  model: 'unknown',
                ),
              );
            }
            if (!controller.isClosed) {
              controller.close();
            }
          },
          cancelOnError: false,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );

    return controller.stream;
  }

  bool _hasPartialSearchTag(String text) {
    for (int i = 1; i <= _searchTagStart.length; i++) {
      if (text.endsWith(_searchTagStart.substring(0, i))) {
        return true;
      }
    }
    return false;
  }
}
