import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';

class OrchestratorStateEngine extends Bloc<ChatEvent, ChatState> {
  static const _logTag = 'ORCHESTRATOR_STATE';
  static int _instanceCreateCount = 0;
  static int _instanceDisposeCount = 0;

  static const Duration _preInferenceUiTimeoutDebug = Duration(seconds: 140);
  static const Duration _preInferenceUiTimeoutRelease = Duration(seconds: 55);
  static Duration get _preInferenceUiTimeout =>
      kDebugMode ? _preInferenceUiTimeoutDebug : _preInferenceUiTimeoutRelease;

  OrchestratorStateEngine({
    required IChatRepository chatRepository,
  })  : _chatRepository = chatRepository,
        super(const ChatInitial()) {
    _instanceCreateCount++;
    _log(
      '[PROVIDER_CREATE] type=OrchestratorStateEngine hash=${hashCode.toRadixString(16)} create_count=$_instanceCreateCount dispose_count=$_instanceDisposeCount',
    );
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<PruneHistoryEvent>(_onPruneHistory);
    on<RecoverFromStuckUiEvent>(_onRecoverFromStuckUi);
    on<DebugClearChatEvent>(_onDebugClearChat);
  }

  final IChatRepository _chatRepository;
  List<ChatMessage> _messages = [];
  bool _sendInFlight = false;

  Future<void> _onLoadMessages(
      LoadMessagesEvent event, Emitter<ChatState> emit) async {
    _log('listener load_messages session=${event.sessionId}');
    emit(const ChatLoading());
    try {
      final messages = await _chatRepository.getMessages(event.sessionId);
      _messages = List<ChatMessage>.from(messages);
      _log('message persistence load_complete session=${event.sessionId} count=${_messages.length}');
      emit(ChatLoaded(messages: List.unmodifiable(_messages)));
    } catch (error) {
      emit(ChatError(message: _extractErrorMessage(error)));
    }
  }

  Future<void> _onSendMessage(
      SendMessageEvent event, Emitter<ChatState> emit) async {
    if (_sendInFlight) {
      _log(
        '[ENTRY_REENTRANCY_BLOCK] scope=OrchestratorStateEngine session=${event.sessionId} hash=${hashCode.toRadixString(16)}',
      );
      emit(
        ChatLoaded(
          messages: List.unmodifiable(_messages),
          runtimeMessage: 'Another send is already running. Please wait.',
        ),
      );
      return;
    }
    _sendInFlight = true;
    try {
      await runInferenceGuarded<void>(
        scope: 'orchestrator_state_engine.send_message',
        log: _log,
        action: () async {
          _log('[VM_SEND] session=${event.sessionId} hash=${hashCode.toRadixString(16)}');
          _log('[ORCHESTRATOR_SEND] session=${event.sessionId} stage=state_engine_send');
          _log('[ORCHESTRATOR_BEGIN] session=${event.sessionId}');
          _log(
            'listener send_message session=${event.sessionId} prompt_chars=${event.userPrompt.length} attachments=${event.attachments.length}',
          );
          final now = DateTime.now().millisecondsSinceEpoch;
          final optimisticUserMessage = ChatMessage(
            id: 'pending-user-$now',
            sessionId: event.sessionId,
            role: 'user',
            content: event.userPrompt,
            timestamp: now,
            attachments: event.attachments,
          );
          final shouldShowAssistantPlaceholder =
              event.userPrompt.trim().isNotEmpty || event.attachments.isEmpty;
          final optimisticAssistantMessage = ChatMessage(
            id: 'pending-assistant-$now',
            sessionId: event.sessionId,
            role: 'assistant',
            content: '',
            timestamp: now + 1,
            provider: 'assistant',
          );

          String? runtimeNotice;
          // Tracks the latest accumulated streaming content so that
          // onRuntimeNotice can re-emit the correct partial text instead of
          // resetting the assistant bubble to empty.  This variable is the
          // fix for the Fake Message Menu content regression: previously,
          // every runtime notice wiped the streamed content because it
          // emitted optimisticAssistantMessage.content (always '').
          var latestPartialContent = '';
          emit(
            ChatSending(
              messages: List.unmodifiable(<ChatMessage>[
                ..._messages,
                optimisticUserMessage,
                if (shouldShowAssistantPlaceholder) optimisticAssistantMessage,
              ]),
            ),
          );

          try {
            var streamStarted = false;
            final sendFuture = _chatRepository.sendMessage(
              sessionId: event.sessionId,
              userPrompt: event.userPrompt,
              systemPrompt: event.systemPrompt,
              attachments: event.attachments,
              onPartialResponse: (partialText) {
                if (emit.isDone) return;
                latestPartialContent = partialText;
                if (partialText.trim().isNotEmpty && !streamStarted) {
                  streamStarted = true;
                  _log('[UI_STREAM_BEGIN] session=${event.sessionId}');
                }
                _log(
                  'streaming callbacks session=${event.sessionId} partial_chars=${partialText.length}',
                );
                emit(
                  ChatSending(
                    messages: List.unmodifiable(<ChatMessage>[
                      ..._messages,
                      optimisticUserMessage,
                      optimisticAssistantMessage.copyWith(content: partialText),
                    ]),
                    runtimeMessage: runtimeNotice,
                  ),
                );
              },
              onRuntimeNotice: (notice) {
                runtimeNotice = notice;
                if (emit.isDone) return;
                _log(
                  'streaming callbacks session=${event.sessionId} runtime_notice="$notice"',
                );
                // Use latestPartialContent to preserve accumulated streaming
                // text.  Using optimisticAssistantMessage.content (always '')
                // would erase all streamed tokens whenever a notice fires.
                emit(
                  ChatSending(
                    messages: List.unmodifiable(<ChatMessage>[
                      ..._messages,
                      optimisticUserMessage,
                      if (shouldShowAssistantPlaceholder)
                        optimisticAssistantMessage.copyWith(
                          content: latestPartialContent,
                        ),
                    ]),
                    runtimeMessage: runtimeNotice,
                  ),
                );
              },
            );
            await sendFuture.timeout(
              _preInferenceUiTimeout,
              onTimeout: () {
                if (!streamStarted) {
                  throw TimeoutException(
                    '[TERMINAL_STATE] state=stalled_pre_inference session=${event.sessionId}',
                  );
                }
                return sendFuture;
              },
            );
            final messages = await _chatRepository.getMessages(event.sessionId);
            _messages = List<ChatMessage>.from(messages);
            _log('message persistence send_complete session=${event.sessionId} count=${_messages.length}');
            emit(
              ChatLoaded(
                messages: List.unmodifiable(_messages),
                runtimeMessage: runtimeNotice,
              ),
            );
            _log('[UI_STREAM_END] session=${event.sessionId}');
          } catch (error) {
            _log('send_message error session=${event.sessionId}: $error');
            if (error is TimeoutException) {
              _log(
                '[TERMINAL_STATE] state=stalled_pre_inference session=${event.sessionId}'
                ' reason=orchestrator_timeout_${_preInferenceUiTimeout.inSeconds}s',
              );
            }
            emit(
              ChatLoaded(
                messages: List.unmodifiable(_messages),
                runtimeMessage: _extractErrorMessage(error),
                suggestOpeningSettings: _shouldSuggestOpeningSettings(error),
              ),
            );
          } finally {
            _log('[ORCHESTRATOR_END] session=${event.sessionId}');
          }
        },
        onError: (error, stackTrace) {
          if (!emit.isDone) {
            emit(
              ChatLoaded(
                messages: List.unmodifiable(_messages),
                runtimeMessage: _extractErrorMessage(error),
                suggestOpeningSettings: _shouldSuggestOpeningSettings(error),
              ),
            );
          }
          _log('[ASYNC_FATAL] scope=orchestrator_state_engine.send_message error=$error stack=$stackTrace');
        },
      );
    } finally {
      _sendInFlight = false;
    }
  }

  Future<void> _onPruneHistory(
      PruneHistoryEvent event, Emitter<ChatState> emit) async {
    await _chatRepository.pruneHistory(
      maxAgeDays: AppConstants.chatHistoryMaxAgeDays,
      maxRows: AppConstants.chatHistoryMaxRows,
    );
  }

  Future<void> _onRecoverFromStuckUi(
    RecoverFromStuckUiEvent event,
    Emitter<ChatState> emit,
  ) async {
    _log('[inference_loop_detected] session=${event.sessionId} source=orchestrator');
    emit(
      ChatLoaded(
        messages: List.unmodifiable(_messages),
        runtimeMessage: event.runtimeMessage,
      ),
    );
    _log('[ORCHESTRATOR_END] session=${event.sessionId} recovery=forced_ui_unlock');
  }

  Future<void> _onDebugClearChat(
    DebugClearChatEvent event,
    Emitter<ChatState> emit,
  ) async {
    _log('[UI_DEBUG] action=clear_chat_reset_begin session=${event.sessionId}');
    try {
      await _chatRepository.clearSession(event.sessionId);
      _messages = <ChatMessage>[];
      _sendInFlight = false;
      emit(const ChatLoaded(messages: <ChatMessage>[]));
      _log('[UI_DEBUG] action=clear_chat_reset_done session=${event.sessionId}');
    } catch (error) {
      _log(
        '[UI_DEBUG] action=clear_chat_reset_failed session=${event.sessionId} error=$error',
      );
      emit(
        ChatLoaded(
          messages: List.unmodifiable(_messages),
          runtimeMessage: _extractErrorMessage(error),
          suggestOpeningSettings: _shouldSuggestOpeningSettings(error),
        ),
      );
    }
  }

  String _extractErrorMessage(Object error) {
    if (error is Failure && error.message.trim().isNotEmpty) {
      return error.message;
    }
    return error.toString();
  }

  bool _shouldSuggestOpeningSettings(Object error) {
    final message = _extractErrorMessage(error).toLowerCase();
    return message.contains('settings') ||
        message.contains('api key') ||
        message.contains('not configured') ||
        message.contains('switch to local ai mode');
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  @override
  Future<void> close() {
    _instanceDisposeCount++;
    _log(
      '[VM_DISPOSE] type=OrchestratorStateEngine hash=${hashCode.toRadixString(16)} create_count=$_instanceCreateCount dispose_count=$_instanceDisposeCount',
    );
    _log(
      '[PROVIDER_DISPOSE] type=OrchestratorStateEngine hash=${hashCode.toRadixString(16)} create_count=$_instanceCreateCount dispose_count=$_instanceDisposeCount',
    );
    return super.close();
  }
}
