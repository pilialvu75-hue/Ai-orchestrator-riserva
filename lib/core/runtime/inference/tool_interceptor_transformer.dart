import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Intercepts streaming inference responses looking for a `<search>...</search>`
/// tool-call.
///
/// The transformer preserves normal inference streaming while withholding only
/// the minimum amount of text necessary to determine whether a search tool-call
/// is being produced.
///
/// When a complete search tag is detected, a runtime notice containing the
/// extracted query is emitted and the upstream subscription is cancelled.
///
/// Important:
/// - Normal tokens are forwarded exactly once.
/// - Partial `<search>` prefixes are retained across chunks.
/// - Text preceding a search tag is emitted before the tool notice.
/// - Text following `</search>` is intentionally not emitted because the
///   search tool-call terminates the current inference stream.
/// - Error responses are forwarded immediately.
/// - Empty responses are forwarded immediately.
/// - Terminal stream completion flushes any safe residual text.
/// - Final responses preserve their original metadata.
/// - No unbounded regular-expression scan is performed on every token.
class ToolInterceptorTransformer
    extends StreamTransformerBase<InferenceResponse, InferenceResponse> {
  static const String _searchTagStart = '<search>';
  static const String _searchTagEnd = '</search>';

  @override
  Stream<InferenceResponse> bind(Stream<InferenceResponse> stream) {
    late StreamController<InferenceResponse> controller;
    StreamSubscription<InferenceResponse>? subscription;

    controller = StreamController<InferenceResponse>(
      sync: true,
      onListen: () {
        final buffer = StringBuffer();
        var streamTerminated = false;
        String? lastModel;

        void emitToken(
          String text, {
          InferenceResponse? source,
        }) {
          if (text.isEmpty || controller.isClosed) {
            return;
          }

          /*
           * Preserve the original response metadata whenever possible.
           *
           * In particular, the previous implementation converted every
           * normal response into InferenceResponse.token(), which silently
           * discarded isFinal, terminalState and tokensGenerated.
           *
           * That caused a final cumulative snapshot such as:
           *
           *   "Hello world"
           *
           * to become a non-final token, making InferenceService append it
           * after the already streamed "Hello world".
           */
          if (source != null) {
            controller.add(
              InferenceResponse(
                text: text,
                model: source.model ?? lastModel,
                tokensGenerated: source.tokensGenerated,
                timestamp: source.timestamp,
                isFinal: source.isFinal,
                isError: source.isError,
                errorMessage: source.errorMessage,
                runtimeNotice: source.runtimeNotice,
                terminalState: source.terminalState,
              ),
            );
            return;
          }

          controller.add(
            InferenceResponse.token(
              text: text,
              model: lastModel ?? 'unknown',
            ),
          );
        }

        void emitSearchNotice(String query) {
          if (controller.isClosed) {
            return;
          }

          RuntimeEventLog.instance.emit(
            '[TOOL_INTERCEPTOR] '
            'target=search '
            'status=extracted '
            'query="$query"',
          );

          controller.add(
            InferenceResponse.notice(
              'search:$query',
            ),
          );
        }

        Future<void> terminateAfterSearch() async {
          if (streamTerminated) {
            return;
          }

          streamTerminated = true;

          await subscription?.cancel();

          if (!controller.isClosed) {
            await controller.close();
          }
        }

        void processBuffer(InferenceResponse response) {
          if (streamTerminated || controller.isClosed) {
            return;
          }

          final text = buffer.toString();

          if (text.isEmpty) {
            /*
             * Preserve empty responses containing metadata/state exactly as
             * they arrived.
             */
            if (response.text.isEmpty) {
              controller.add(response);
            }

            return;
          }

          final searchStartIndex = text.indexOf(_searchTagStart);

          // No complete opening tag yet.
          if (searchStartIndex == -1) {
            final safeLength = _safeFlushLength(text);

            if (safeLength > 0) {
              /*
               * If this response is final, the safe text is itself the
               * terminal response. Preserve its final metadata.
               */
              final isEntireBufferedResponse =
                  safeLength == text.length;

              if (response.isFinal && isEntireBufferedResponse) {
                emitToken(
                  text,
                  source: response,
                );

                buffer.clear();
                return;
              }

              emitToken(text.substring(0, safeLength));

              final remainder = text.substring(safeLength);

              buffer
                ..clear()
                ..write(remainder);
            }

            return;
          }

          // We have found the opening tag.
          //
          // Everything before it is ordinary model output and can safely be
          // forwarded before we start withholding the tool-call.
          if (searchStartIndex > 0) {
            emitToken(text.substring(0, searchStartIndex));

            final remainder = text.substring(searchStartIndex);

            buffer
              ..clear()
              ..write(remainder);
          }

          final bufferedText = buffer.toString();

          final endIndex = bufferedText.indexOf(
            _searchTagEnd,
            _searchTagStart.length,
          );

          // Opening tag exists, but the closing tag has not arrived yet.
          // Keep everything buffered.
          if (endIndex == -1) {
            return;
          }

          final query = bufferedText
              .substring(
                _searchTagStart.length,
                endIndex,
              )
              .trim();

          // Consume the complete search expression.
          buffer.clear();

          emitSearchNotice(query);

          // A search tool-call represents a terminal event for this inference
          // stream. The orchestrator is responsible for starting the next
          // phase after executing the tool.
          unawaited(terminateAfterSearch());
        }

        subscription = stream.listen(
          (response) {
            if (streamTerminated || controller.isClosed) {
              return;
            }

            if (response.isError) {
              controller.add(response);
              return;
            }

            final textChunk = response.text;

            if (response.model != null &&
                response.model!.isNotEmpty) {
              lastModel = response.model;
            }

            // Empty responses can contain useful metadata/state, so preserve
            // them exactly as received.
            if (textChunk.isEmpty) {
              controller.add(response);
              return;
            }

            buffer.write(textChunk);

            processBuffer(response);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (controller.isClosed) {
              return;
            }

            controller.addError(
              error,
              stackTrace,
            );
          },
          onDone: () {
            if (streamTerminated || controller.isClosed) {
              return;
            }

            final pendingText = buffer.toString();

            if (pendingText.isNotEmpty) {
              final searchStartIndex =
                  pendingText.indexOf(_searchTagStart);

              if (searchStartIndex == -1) {
                // If the pending text ends with a partial `<search>` opening
                // tag, that fragment is deliberately discarded.
                //
                // Otherwise all remaining text is safe to emit.
                if (!_hasPartialSearchTag(pendingText)) {
                  emitToken(pendingText);
                }
              } else if (searchStartIndex > 0) {
                // Preserve normal text before an incomplete search tag.
                emitToken(
                  pendingText.substring(0, searchStartIndex),
                );
              }

              // Any incomplete `<search>...` fragment is deliberately
              // discarded. It is not a valid tool-call.
            }

            buffer.clear();

            if (!controller.isClosed) {
              unawaited(
                controller.close(),
              );
            }
          },
          cancelOnError: false,
        );
      },
      onPause: () {
        subscription?.pause();
      },
      onResume: () {
        subscription?.resume();
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  /// Returns the amount of text that is safe to emit while preserving enough
  /// trailing characters to detect a `<search>` opening tag split across
  /// multiple inference chunks.
  ///
  /// Example:
  ///
  ///   "Hello <sea"
  ///
  /// The `"Hello "` portion is safe, while `"<sea"` must remain buffered.
  int _safeFlushLength(String text) {
    if (text.isEmpty) {
      return 0;
    }

    const maxPrefixLength =
        _searchTagStart.length - 1;

    final maximumCheckLength =
        text.length < maxPrefixLength
            ? text.length
            : maxPrefixLength;

    for (
      int length = maximumCheckLength;
      length > 0;
      length--
    ) {
      final suffix = text.substring(
        text.length - length,
      );

      if (_searchTagStart.startsWith(suffix)) {
        return text.length - length;
      }
    }

    return text.length;
  }

  /// Kept as a dedicated helper because partial-tag detection is part of the
  /// transformer's parsing contract.
  ///
  /// This method intentionally checks only the end of the supplied text.
  bool _hasPartialSearchTag(String text) {
    if (text.isEmpty) {
      return false;
    }

    final maxLength =
        text.length < _searchTagStart.length
            ? text.length
            : _searchTagStart.length - 1;

    for (
      int length = 1;
      length <= maxLength;
      length++
    ) {
      if (text.endsWith(
        _searchTagStart.substring(
          0,
          length,
        ),
      )) {
        return true;
      }
    }

    return false;
  }
}
