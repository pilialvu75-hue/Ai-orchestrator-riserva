import 'dart:async';

import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
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
    required this.conversationMemoryService,
    Orchestrator? orchestrator,
    Orchestrator Function()? orchestratorProvider,
    this.inferenceService,
    this.runtimeSettingsService,
  })  : _orchestrator = orchestrator,
        _orchestratorProvider = orchestratorProvider;

  final ChatLocalDataSource localDataSource;
  final ConversationMemoryService conversationMemoryService;

  /// Optional eager Orchestrator kept for compatibility with existing tests
  /// and callers. Production DI uses [_orchestratorProvider] so explicit Cloud
  /// chat does not instantiate Hannibal at all.
  final Orchestrator? _orchestrator;
  final Orchestrator Function()? _orchestratorProvider;

  /// Direct inference dependencies used only by explicit Cloud mode.
  final InferenceService? inferenceService;
  final AiRuntimeSettingsService? runtimeSettingsService;

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
            throw const ServerFailure(
              'A response is already in progress for this session.',
            );
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
            _log(
              'message persistence session=$sessionId role=user id=${userMsg.id}',
            );
            await conversationMemoryService.storeMessageEmbedding(
              sessionId: sessionId,
              messageId: userMsg.id,
              role: userMsg.role,
              content: userMsg.content,
              timestamp: userMsg.timestamp,
            );

            if (normalizedPrompt.isEmpty && attachments.isNotEmpty) {
              final forensicMessage =
                  '[PRE_STREAM_BYPASS] session=$sessionId boundary=chat_repository.attachments_only reason=empty_prompt_with_attachments target=inference_not_invoked attachments=${attachments.length}';
              _log(forensicMessage);
              RuntimeEventLog.instance.emit(forensicMessage);
              return userMsg;
            }

            final sessionMessages =
                await localDataSource.getMessages(sessionId);
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

            final previousSubscription =
                _activeInferenceSubscriptions[sessionId];
            if (previousSubscription != null) {
              _log(
                '[DUPLICATE_SUBSCRIPTION] session=$sessionId action=cancel_previous',
              );
              await previousSubscription.cancel();
              _activeInferenceSubscriptions.remove(sessionId);
            }

            final contextSnapshot = List<ChatTurn>.unmodifiable(context);
            final stream = _buildInferenceStream(
              sessionId: sessionId,
              prompt: normalizedPrompt,
              systemPrompt: systemPrompt,
              context: contextSnapshot,
            );
            final streamCompleter = Completer<void>();
            final abortSignal = Completer<void>();
            _sessionAbortSignals[sessionId] = abortSignal;

            // Ensures listener setup failures still release the abort signal.
            try {
              _log(
                '[STREAM_LISTENER_ATTACH] session=$sessionId listener=chat_repository_stream_listener',
              );
              final subscription = stream.listen(
                (chunk) {
                  try {
                    final providerId = chunk.providerId?.trim();
                    if (providerId != null && providerId.isNotEmpty) {
                      responseProvider = providerId;
                    }

                    if (chunk.runtimeNotice != null &&
                        chunk.runtimeNotice!.trim().isNotEmpty) {
                      final notice = chunk.runtimeNotice!.trim();
                      _log(
                        '[TOKEN_STREAM] session=$sessionId runtime_notice="$notice" provider=$responseProvider',
                      );

                      if (notice.startsWith('cloud_provider:')) {
                        final activeProvider = notice
                            .substring('cloud_provider:'.length)
                            .trim();
                        if (activeProvider.isNotEmpty) {
                          responseProvider = activeProvider;
                          onRuntimeNotice?.call(
                            'Cloud provider: ${_providerDisplayName(activeProvider)}',
                          );
                        }
                      } else {
                        onRuntimeNotice?.call(notice);
                      }
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
                      if ((providerId == null || providerId.isEmpty) &&
                          chunk.model != null &&
                          chunk.model!.trim().isNotEmpty) {
                        responseProvider = chunk.model!;
                      }
                      _log(
                        '[FINAL_RESPONSE] session=$sessionId is_final=true tokens=${chunk.tokensGenerated} provider=$responseProvider',
                      );
                    } else {
                      streamedResponse.write(chunk.text);
                      _log(
                        '[TOKEN_STREAM] session=$sessionId partial_chars=${streamedResponse.length} provider=$responseProvider',
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
                  _log(
                    '[CHAT_PIPELINE] action=stream_aborted session=$sessionId',
                  );
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
              throw const ServerFailure(
                'Inference returned an empty response.',
              );
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
            _log(
              '[FINAL_RESPONSE] persistence session=$sessionId role=assistant id=${assistantMsg.id} provider=$responseProvider',
            );
            return assistantMsg;
          } finally {
            _activeSendSessions.remove(sessionId);
          }
        },
        onError: (error, stackTrace) {
          _log(
            '[ASYNC_FATAL] scope=chat_repository.send_message session=$sessionId error=$error stack=$stackTrace',
          );
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

  Stream<InferenceResponse> _buildInferenceStream({
    required String sessionId,
    required String prompt,
    required String? systemPrompt,
    required List<ChatTurn> context,
  }) {
    final settings = runtimeSettingsService;
    final directInference = inferenceService;

    if (settings?.runtimeMode == AiRuntimeMode.cloud && directInference != null) {
      _log(
        '[CLOUD_DIRECT_ROUTE] session=$sessionId orchestrator_bypassed=true provider_authority=cloud_router',
      );
      _log(
        '[STREAM_SUBSCRIBE] session=$sessionId stream=inference_service.direct_cloud hash=${hashCode.toRadixString(16)}',
      );

      return directInference.stream(
        InferenceRequest(
          sessionId: sessionId,
          requestId: _uuid.v4(),
          prompt: prompt,
          systemPrompt: systemPrompt,
          context: context,
          isOffline: false,
          routeDirective: InferenceRouteDirective.cloudOnly,
          allowCloudProviderFailover: true,
        ),
      );
    }

    final resolvedOrchestrator = _resolveOrchestrator();
    _log(
      '[ORCHESTRATOR_SEND] session=$sessionId scope=chat_repository.handleStream mode=${settings?.runtimeMode.name ?? 'unknown'}',
    );
    _log(
      '[STREAM_SUBSCRIBE] session=$sessionId stream=orchestrator.handleStream hash=${hashCode.toRadixString(16)}',
    );

    return resolvedOrchestrator.handleStream(
      prompt,
      sessionId: sessionId,
      context: context,
      systemPrompt: systemPrompt,
    );
  }

  Orchestrator _resolveOrchestrator() {
    final eager = _orchestrator;
    if (eager != null) return eager;

    final provider = _orchestratorProvider;
    if (provider != null) return provider();

    throw StateError(
      'Orchestrator is unavailable for Local/Hybrid chat. '
      'Explicit Cloud chat remains independent when direct inference is configured.',
    );
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
        Error.throwWithStackTrace(
          error,
          stackTrace ?? StackTrace.current,
        );
      }
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) async {
    try {
      return await localDataSource.deleteMessagesFrom(
        sessionId,
        messageId,
      );
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

  static String _providerDisplayName(String providerId) {
    switch (providerId) {
      case 'openAi':
        return 'OpenAI';
      case 'gemini':
        return 'Gemini';
      case 'claude':
        return 'Claude';
      case 'grok':
        return 'Grok';
      case 'copilot':
        return 'GitHub Copilot';
      default:
        return providerId;
    }
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  Future<void> _cancelActiveSubscription(String sessionId) async {
    final activeSubscription =
        _activeInferenceSubscriptions.remove(sessionId);

    if (activeSubscription != null) {
      await activeSubscription.cancel();
    }
  }
}
