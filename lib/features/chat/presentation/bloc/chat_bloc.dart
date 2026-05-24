import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final StreamChatMessage streamChatMessage;
  final LoadChatMessages loadChatMessages;
  final PruneChatHistory pruneChatHistory;

  List<ChatMessage> _messages = [];
  final String _activeProvider;

  ChatBloc({
    required this.streamChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    String initialProvider = 'openAi',
  })  : _activeProvider = initialProvider,
        super(const ChatInitial()) {
    
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<PruneHistoryEvent>((event, emit) => _messages.clear());
  }

  Future<void> _onLoadMessages(LoadMessagesEvent event, Emitter<ChatState> emit) async {
    emit(const ChatLoading());
    final result = await loadChatMessages(LoadChatMessagesParams(sessionId: event.sessionId));
    
    if (isClosed) return;

    result.fold(
      (failure) => emit(ChatError(message: failure.message)),
      (messages) {
        _messages = List<ChatMessage>.from(messages);
        emit(ChatLoaded(messages: List.unmodifiable(_messages), activeProvider: _activeProvider));
      },
    );
  }

  Future<void> _onSendMessage(SendMessageEvent event, Emitter<ChatState> emit) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    
    // 1. Aggiunta ottimistica del messaggio utente
    _messages.add(ChatMessage(
      id: 'user-$now',
      sessionId: event.sessionId,
      role: 'user',
      content: event.userPrompt,
      timestamp: now,
      attachments: event.attachments,
    ));

    ChatMessage? lastAssistantMessage;

    // 2. Consuma lo stream (Soddisfa la richiesta del test: "incremental assistant updates")
    await for (final assistantMessage in streamChatMessage(
      StreamChatMessageParams(
        sessionId: event.sessionId,
        userPrompt: event.userPrompt,
        systemPrompt: event.systemPrompt,
        attachments: event.attachments,
        activeProvider: _activeProvider,
      ),
    )) {
      if (isClosed) return;
      lastAssistantMessage = assistantMessage;
      
      emit(ChatSending(
        messages: List.unmodifiable([..._messages, assistantMessage]),
        activeProvider: _activeProvider,
      ));
    }

    if (lastAssistantMessage != null) {
      _messages.add(lastAssistantMessage);
    }

    if (!isClosed) {
      emit(ChatLoaded(messages: List.unmodifiable(_messages), activeProvider: _activeProvider));
      
      // 3. Ricarica i messaggi salvati (Soddisfa la richiesta del test: "before loading persisted messages")
      add(LoadMessagesEvent(sessionId: event.sessionId));
    }
  }
}
