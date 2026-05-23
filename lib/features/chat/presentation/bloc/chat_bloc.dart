import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  static const _logTag = 'CHAT_BLOC';

  ChatBloc({
    required this.streamChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    String initialProvider = 'openAi',
  })  : _activeProvider = initialProvider,
        super(const ChatInitial()) {
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<PruneHistoryEvent>(_onPruneHistory);
  }

  final StreamChatMessage streamChatMessage;
  final LoadChatMessages loadChatMessages;
  final PruneChatHistory pruneChatHistory;

  final String _activeProvider;
  List<ChatMessage> _messages = [];

  Future<void> _onLoadMessages(
      LoadMessagesEvent event, Emitter<ChatState> emit) async {
    try {
      emit(const ChatLoading());
      final result = await loadChatMessages(
          LoadChatMessagesParams(sessionId: event.sessionId));

      if (isClosed) return;

      result.fold(
        (failure) {
          _log(
            '[LOAD_MESSAGES_FAIL] session=${event.sessionId} error=${failure.message}',
          );
          emit(ChatError(message: failure.message));
        },
        (messages) {
          _log(
            '[LOAD_MESSAGES_OK] session=${event.sessionId} count=${messages.length}',
          );
          _messages = List<ChatMessage>.from(messages);
          emit(ChatLoaded(
              messages: List.unmodifiable(_messages),
              activeProvider: _activeProvider));
        },
      );
    } catch (e, stackTrace) {
      _log(
        '[CHAT_BLOC_FATAL] scope=loadMessages session=${event.sessionId} error=$e stack=$stackTrace',
      );
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  Future<void> _onSendMessage(
      SendMessageEvent event, Emitter<ChatState> emit) async {
    try {
      _log(
        '[CHAT_SEND_BEGIN] session=${event.sessionId} prompt_chars=${event.userPrompt.length} attachments=${event.attachments.length}',
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
      final optimisticAssistantMessage = ChatMessage(
        id: 'pending-assistant-$now',
        sessionId: event.sessionId,
        role: 'assistant',
        content: '',
        timestamp: now + 1,
        provider: _activeProvider,
      );
      final shouldShowAssistantPlaceholder =
          event.userPrompt.trim().isNotEmpty || event.attachments.isEmpty;

      emit(ChatSending(
          messages: List.unmodifiable(<ChatMessage>[
            ..._messages,
            optimisticUserMessage,
            if (shouldShowAssistantPlaceholder) optimisticAssistantMessage,
          ]),
          activeProvider: _activeProvider));

      await for (final assistantMessage in streamChatMessage(
        StreamChatMessageParams(
          sessionId: event.sessionId,
          userPrompt: event.userPrompt,
          systemPrompt: event.systemPrompt,
          attachments: event.attachments,
          activeProvider: _activeProvider,
        ),
      )) {
        _log(
          '[CHAT_STREAM_CHUNK] session=${event.sessionId} role=${assistantMessage.role} chars=${assistantMessage.content.length}',
        );
        if (isClosed) return;
        emit(ChatSending(
          messages: List.unmodifiable(<ChatMessage>[
            ..._messages,
            optimisticUserMessage,
            assistantMessage,
          ]),
          activeProvider: _activeProvider,
        ));
      }

      if (!isClosed) {
        _log('[CHAT_SEND_COMPLETE] session=${event.sessionId} reload=true');
        add(LoadMessagesEvent(sessionId: event.sessionId));
      }
    } catch (e, stackTrace) {
      _log(
        '[CHAT_BLOC_FATAL] scope=sendMessage session=${event.sessionId} error=$e stack=$stackTrace',
      );
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  Future<void> _onPruneHistory(
      PruneHistoryEvent event, Emitter<ChatState> emit) async {
    try {
      await pruneChatHistory(const PruneChatHistoryParams());
    } catch (e, stackTrace) {
      _log(
        '[CHAT_BLOC_FATAL] scope=pruneHistory error=$e stack=$stackTrace',
      );
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  static void _log(String message) {
    RuntimeEventLog.instance.emit('[$_logTag] $message');
  }
}
