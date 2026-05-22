import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/send_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required this.sendChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    String initialProvider = 'openAi',
  })  : _activeProvider = initialProvider,
        super(const ChatInitial()) {
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<PruneHistoryEvent>(_onPruneHistory);
  }

  final SendChatMessage sendChatMessage;
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
        (failure) => emit(ChatError(message: failure.message)),
        (messages) {
          _messages = List<ChatMessage>.from(messages);
          emit(ChatLoaded(
              messages: List.unmodifiable(_messages),
              activeProvider: _activeProvider));
        },
      );
    } catch (e) {
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  Future<void> _onSendMessage(
      SendMessageEvent event, Emitter<ChatState> emit) async {
    try {
      emit(ChatSending(
          messages: List.unmodifiable(_messages),
          activeProvider: _activeProvider));

      final result = await sendChatMessage(SendChatMessageParams(
        sessionId: event.sessionId,
        userPrompt: event.userPrompt,
        systemPrompt: event.systemPrompt,
      ));

      if (isClosed) return;

      result.fold(
        (failure) => emit(ChatError(message: failure.message)),
        (_) {
          if (!isClosed) {
            add(LoadMessagesEvent(sessionId: event.sessionId));
          }
        },
      );
    } catch (e) {
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  Future<void> _onPruneHistory(
      PruneHistoryEvent event, Emitter<ChatState> emit) async {
    try {
      await pruneChatHistory(const PruneChatHistoryParams());
    } catch (e) {
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }
}
