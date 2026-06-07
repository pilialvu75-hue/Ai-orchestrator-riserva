import 'dart:async';

import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/stream_text_accumulator.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

class ChatRepositoryImpl implements ChatRepository {
  static const _logTag = 'CHAT_PIPELINE';

  ChatRepositoryImpl({
    required this.localDataSource,
    required this.orchestrator,
    required this.conversationMemoryService,
  });

  final ChatLocalDataSource localDataSource;
  final Orchestrator orchestrator;
  final ConversationMemoryService conversationMemoryService;

  static const _uuid = Uuid();
  final Set<String> _activeSendSessions = <String>{};
  final Map<String, Completer<void>> _sessionAbortSignals =
      <String, Completer<void>>{};
  final Map<String, StreamSubscription<InferenceResponse>>
      _activeInferenceSubscriptions =
      <String, StreamSubscription<InferenceResponse>>{};

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    try {
      final messages = await localDataSource.getMessages(sessionId);
      return messages;
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async {
    try {
      return await runInferenceGuarded<ChatMessage>(
        scope: 'chat_repository.send_message',
        log: _log,
        action: () async {
          if (!_activeSendSessions.add(sessionId)) {
            _log(
              '[ENTRY_REENTRANCY_BLOCK] scope=chat_repository session=$sessionId hash=${hashCode.toRadixString(16)}',
            );
            throw const ServerFailure('A response is already in progress for this session.');
          }
          try {
            final attachmentsSnapshot =
                List<ChatAttachment>.unmodifiable(attachments);
            RuntimeEventLog.instance.emit(
              '[FORENSIC_CONVERSATION_START] session=$sessionId prompt_chars=${userPrompt.trim().length} attachments=${attachmentsSnapshot.length}',
            );
            final normalizedPrompt = userPrompt.trim();
            _log(
              'prompt creation session=$sessionId prompt_chars=${normalizedPrompt.length} attachments=${attachmentsSnapshot.length}',
            );
            final userMsg = ChatMessageModel(
              id: _uuid.v4(),
              sessionId: sessionId,
              role: 'user',
              content: normalizedPrompt,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              attachments: attachmentsSnapshot,
            );
            await localDataSource.insertMessage(userMsg);
            _log('message persistence session=$sessionId role=user id=${userMsg.id}');
            await conversationMemoryService.storeMessageEmbedding(
              sessionId: sessionId,
              messageId: userMsg.id,
              role: userMsg.role,
              content: userMsg.content,
              timestamp: userMsg.timestamp,
            );

            if (normalizedPrompt.isEmpty && attachments.isNotEmpty) {
              final forensicMessage =
                  '[PRE_STREAM_BYPASS] session=$sessionId boundary=chat_repository.attachments_only reason=empty_prompt_with_attachments target=orchestrator_not_invoked attachments=${attachments.length}';
              _log(forensicMessage);
              RuntimeEventLog.instance.emit(forensicMessage);
              return userMsg;
            }

            final sessionMessages = await localDataSource.getMessages(sessionId);
            final context = await conversationMemoryService.buildContext(
              sessionId: sessionId,
              messages: sessionMessages,
              userPrompt: normalizedPrompt,
              systemPrompt: systemPrompt,
              excludedMessageId: userMsg.id,
            );
            _log(
              'memory retrieval session=$sessionId history_count=${sessionMessages.length} context_injected=${context.length}',
            );

            final streamedResponse = StringBuffer();
            String responseProvider = 'local';

            _log(
              '[ORCHESTRATOR_SEND] session=$sessionId scope=chat_repository.handleStream',
            );
            _log(
              '[STREAM_SUBSCRIBE] session=$sessionId stream=orchestrator.handleStream hash=${hashCode.toRadixString(16)}',
            );
            final previousSubscription = _activeInferenceSubscriptions[sessionId];
            if (previousSubscription != null) {
              _log(
                '[DUPLICATE_SUBSCRIPTION] session=$sessionId action=cancel_previous',
              );
              await previousSubscription.cancel();
              _activeInferenceSubscriptions.remove(sessionId);
            }
            final contextSnapshot = List<ChatTurn>.unmodifiable(context);
            final stream = orchestrator.handleStream(
              normalizedPrompt,
              sessionId: sessionId,
              context: contextSnapshot,
              systemPrompt: systemPrompt,
            );
            final streamCompleter = Completer<void>();
            final abortSignal = Completer<void>();
            _sessionAbortSignals[sessionId] = abortSignal;
            // Ensure listener setup failures still release the abort signal.
            try {
              _log(
                '[STREAM_LISTENER_ATTACH] session=$sessionId listener=chat_repository_stream_listener',
              );
              final subscription = stream.listen(
                (chunk) {
                  try {
                    if (chunk.runtimeNotice != null && chunk.runtimeNotice!.trim().isNotEmpty) {
                      _log('[TOKEN_STREAM] session=$sessionId runtime_notice="${chunk.runtimeNotice}"');
                      onRuntimeNotice?.call(chunk.runtimeNotice!);
                      return;
                    }
                    if (chunk.isError) {
                      throw ServerFailure(
                        _normalizeRuntimeErrorMessage(
                          chunk.errorMessage ?? 'Inference failed.',
                        ),
                      );
                    }
                    if (chunk.isFinal) {
                      if (chunk.text.isNotEmpty) {
                        final merged = mergeStreamedText(
                          currentText: streamedResponse.toString(),
                          incomingText: chunk.text,
                          isFinalChunk: true,
                        );
                        streamedResponse.clear();
                        streamedResponse.write(merged);
                      }
                      if (chunk.model != null && chunk.model!.trim().isNotEmpty) {
                        responseProvider = chunk.model!;
                      }
                      _log(
                        '[FINAL_RESPONSE] session=$sessionId is_final=true tokens=${chunk.tokensGenerated} provider=$responseProvider',
                      );
                    } else {
                      streamedResponse.write(chunk.text);
                      _log(
                        '[TOKEN_STREAM] session=$sessionId partial_chars=${streamedResponse.length}',
                      );
                      onPartialResponse?.call(streamedResponse.toString());
                    }
                  } catch (error, stackTrace) {
                    if (!streamCompleter.isCompleted) {
                      streamCompleter.completeError(error, stackTrace);
                    }
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  _log(
                    '[ASYNC_FATAL] scope=chat_repository.stream_listener session=$sessionId error=$error stack=$stackTrace',
                  );
                  if (!streamCompleter.isCompleted) {
                    streamCompleter.completeError(error, stackTrace);
                  }
                },
                onDone: () {
                  if (!streamCompleter.isCompleted) {
                    streamCompleter.complete();
                  }
                },
                cancelOnError: false,
              );
              _activeInferenceSubscriptions[sessionId] = subscription;
              try {
                final wasAborted = await Future.any<bool>([
                  streamCompleter.future.then((_) => false),
                  abortSignal.future.then((_) => true),
                ]);
                if (wasAborted) {
                  _log('[CHAT_PIPELINE] action=stream_aborted session=$sessionId');
                  return userMsg;
                }
              } finally {
                // Always cancel the active subscription before continuing.
                await _cancelActiveSubscription(sessionId);
              }
            } finally {
              if (!abortSignal.isCompleted) {
                abortSignal.complete();
              }
              _sessionAbortSignals.remove(sessionId);
            }

            final responseText = streamedResponse.toString().trim();
            if (responseText.isEmpty) {
              throw const ServerFailure('Inference returned an empty response.');
            }

            final assistantMsg = ChatMessageModel(
              id: _uuid.v4(),
              sessionId: sessionId,
              role: 'assistant',
              content: responseText,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              provider: responseProvider,
            );
            await localDataSource.insertMessage(assistantMsg);
            await conversationMemoryService.storeMessageEmbedding(
              sessionId: sessionId,
              messageId: assistantMsg.id,
              role: assistantMsg.role,
              content: assistantMsg.content,
              timestamp: assistantMsg.timestamp,
            );
            _log('[FINAL_RESPONSE] persistence session=$sessionId role=assistant id=${assistantMsg.id}');
            return assistantMsg;
          } finally {
            _activeSendSessions.remove(sessionId);
          }
        },
        onError: (error, stackTrace) {
          _log('[ASYNC_FATAL] scope=chat_repository.send_message session=$sessionId error=$error stack=$stackTrace');
        },
      );
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } on ServerException catch (e) {
      throw ServerFailure(e.message);
    } on Failure {
      rethrow;
    } catch (e) {
      throw ServerFailure(e.toString());
    }
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) async {
    try {
      final cutoff =
          DateTime.now().subtract(Duration(days: maxAgeDays));
      int deleted = await localDataSource.deleteOldMessages(cutoff);
      final remaining = await localDataSource.countMessages();
      if (remaining > maxRows) {
        deleted += await localDataSource.deleteExcessMessages(maxRows);
      }
      return deleted;
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  @override
  Future<void> clearSession(String sessionId) async {
    try {
      final abortSignal = _sessionAbortSignals.remove(sessionId);
      if (abortSignal != null && !abortSignal.isCompleted) {
        abortSignal.complete();
      }
      await _cancelActiveSubscription(sessionId);
      _activeSendSessions.remove(sessionId);
      Object? error;
      StackTrace? stackTrace;
      try {
        await localDataSource.clearSession(sessionId);
      } catch (e, st) {
        error ??= e;
        stackTrace ??= st;
      }
      try {
        await conversationMemoryService.clearSessionMemory(sessionId);
      } catch (e, st) {
        error ??= e;
        stackTrace ??= st;
      }
      if (error != null) {
        Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current);
      }
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  static String _normalizeRuntimeErrorMessage(String input) {
    const prefix = 'AI_RUNTIME_ERROR|';
    final raw = input.trim();
    if (!raw.startsWith(prefix)) return raw;

    final payload = raw.substring(prefix.length);
    final parts = payload.split('|');
    String? stage;
    String? message;
    String? details;
    for (final part in parts) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim().toLowerCase();
      final value = part.substring(idx + 1).trim();
      if (value.isEmpty) continue;
      if (key == 'stage') stage = value;
      if (key == 'message') message = value;
      if (key == 'details') details = value;
    }

    final buffer = StringBuffer();
    buffer.write(message ?? 'Local runtime failed.');
    if (details != null && details.isNotEmpty) {
      buffer.write('\nDetails: $details');
    }
    if (stage != null && stage.isNotEmpty) {
      buffer.write('\nStage: $stage');
    }
    return buffer.toString();
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  Future<void> _cancelActiveSubscription(String sessionId) async {
    final activeSubscription = _activeInferenceSubscriptions.remove(sessionId);
    if (activeSubscription != null) {
      await activeSubscription.cancel();
    }
  }
}
