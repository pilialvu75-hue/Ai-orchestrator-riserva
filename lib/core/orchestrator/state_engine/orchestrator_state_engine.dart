import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:ai_orchestrator/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';

/// Centralised runtime state engine for all chat + AI-response state.
///
/// Replaces [ChatBloc] and lives in [core/orchestrator/state_engine] so that
/// it is provided at the **app root** level and accessible from every feature
/// (Chat, Settings, etc.) without being scoped to a single route or screen.
///
/// Injection:
/// ```dart
/// BlocProvider<OrchestratorStateEngine>(
///   create: (_) => sl<OrchestratorStateEngine>(),
/// )
/// ```
/// must be placed **above** [MaterialApp] so that all navigated routes share
/// the same instance.
class OrchestratorStateEngine extends Bloc<ChatEvent, ChatState> {
  static const _logTag = 'ORCHESTRATOR_STATE';
  static const Duration _preInferenceUiTimeout = Duration(seconds: 15);

  OrchestratorStateEngine({
    required IChatRepository chatRepository,
  })  : _chatRepository = chatRepository,
        super(const ChatInitial()) {
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<PruneHistoryEvent>(_onPruneHistory);
    on<RecoverFromStuckUiEvent>(_onRecoverFromStuckUi);
  }

  final IChatRepository _chatRepository;
  List<ChatMessage> _messages = [];

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
      // Keep assistant slightly after user so insertion-order rendering remains
      // stable even if UI code later chooses timestamp-aware operations.
      timestamp: now + 1,
      provider: 'assistant',
    );

    String? runtimeNotice;
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
                ChatMessage(
                  id: optimisticAssistantMessage.id,
                  sessionId: optimisticAssistantMessage.sessionId,
                  role: optimisticAssistantMessage.role,
                  content: partialText,
                  timestamp: optimisticAssistantMessage.timestamp,
                  provider: optimisticAssistantMessage.provider,
                ),
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
          emit(
            ChatSending(
              messages: List.unmodifiable(<ChatMessage>[
                ..._messages,
                optimisticUserMessage,
                if (shouldShowAssistantPlaceholder)
                  ChatMessage(
                    id: optimisticAssistantMessage.id,
                    sessionId: optimisticAssistantMessage.sessionId,
                    role: optimisticAssistantMessage.role,
                    content: optimisticAssistantMessage.content,
                    timestamp: optimisticAssistantMessage.timestamp,
                    provider: optimisticAssistantMessage.provider,
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
          ' reason=orchestrator_timeout_15s',
        );
      }
      // Emit the real persisted message list (_messages) without the ephemeral
      // optimistic message so no ghost messages appear in the UI for requests
      // that were never persisted to the database.
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
}
