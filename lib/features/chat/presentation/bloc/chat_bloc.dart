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

  final List<ChatMessage> _messages = [];
  final String _activeProvider;

  ChatBloc({
    required this.streamChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    String initialProvider = 'openAi',
  })  : _activeProvider = initialProvider,
        super(const ChatInitial()) {
    
    // Gestione minima degli eventi per evitare crash
    on<LoadMessagesEvent>((event, emit) => emit(ChatLoaded(messages: List.unmodifiable(_messages), activeProvider: _activeProvider)));
    on<PruneHistoryEvent>((event, emit) => _messages.clear());
    on<SendMessageEvent>(_onSendMessage);
  }

  Future<void> _onSendMessage(SendMessageEvent event, Emitter<ChatState> emit) async {
    if (event.userPrompt.trim().isEmpty) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // 1. Crea e aggiunge il messaggio dell'utente alla lista locale
    _messages.add(ChatMessage(
      id: 'user-$timestamp',
      sessionId: event.sessionId,
      role: 'user',
      content: event.userPrompt,
      timestamp: timestamp,
    ));
    emit(ChatSending(messages: List.unmodifiable(_messages), activeProvider: _activeProvider));

    // 2. Simulazione del tempo di inference (Iniezione logica file base)
    await Future.delayed(const Duration(seconds: 2));

    // 3. Crea e aggiunge la risposta simulata dell'assistente
    _messages.add(ChatMessage(
      id: 'assistant-$timestamp',
      sessionId: event.sessionId,
      role: 'assistant',
      content: "Risposta base per: ${event.userPrompt}",
      timestamp: timestamp + 1,
      provider: _activeProvider,
    ));

    // 4. Ritorna lo stato finale alla UI
    emit(ChatLoaded(messages: List.unmodifiable(_messages), activeProvider: _activeProvider));
  }
}
