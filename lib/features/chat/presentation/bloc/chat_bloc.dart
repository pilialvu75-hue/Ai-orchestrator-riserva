import 'dart:developer' as developer;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/send_chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required this.sendChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    required this.streamChatMessage,
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
  final StreamChatMessage streamChatMessage;

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
          developer.log(
            'FAIL: Impossibile caricare i messaggi per la sessione ${event.sessionId}. Errore: ${failure.message}',
            name: 'ai_orchestrator.ChatBloc',
            level: 900,
          );
          emit(ChatError(message: failure.message));
        },
        (messages) {
          _messages = List<ChatMessage>.from(messages);
          emit(ChatLoaded(
              messages: List.unmodifiable(_messages),
              activeProvider: _activeProvider));
        },
      );
    } catch (e, stackTrace) {
      developer.log(
        'CRITICAL: Eccezione non gestita durante il caricamento dei messaggi',
        name: 'ai_orchestrator.ChatBloc',
        error: e,
        stackTrace: stackTrace,
        level: 1000,
      );
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }

  Future<void> _onSendMessage(
      SendMessageEvent event, Emitter<ChatState> emit) async {
    try {
      // 1. Creazione ed emissione ottimistica immediata dello stato UI
      final updatedMessages = List<ChatMessage>.from(_messages);
      
      // NOTA: Adatta i costruttori di ChatMessage se i tuoi campi entity differiscono
      final userPlaceholder = ChatMessage(
        text: event.userPrompt, 
        isUser: true,
      );
      final assistantPlaceholder = ChatMessage(
        text: '', 
        isUser: false,
      );
      
      updatedMessages.add(userPlaceholder);
      updatedMessages.add(assistantPlaceholder);

      // Mostriamo subito i messaggi sulla UI per eliminare la percezione di lag
      emit(ChatSending(
          messages: List.unmodifiable(updatedMessages),
          activeProvider: _activeProvider));

      // 2. Aggancio allo stream nativo tramite UseCase dedicato
      final messageStream = streamChatMessage(StreamChatMessageParams(
        sessionId: event.sessionId,
        userPrompt: event.userPrompt,
        systemPrompt: event.systemPrompt,
      ));

      await emit.forEach<ChatMessage>(
        messageStream,
        onData: (incomingChunk) {
          // Sostituiamo progressivamente il placeholder dell'assistente con i token parziali accumulati
          if (updatedMessages.isNotEmpty) {
            updatedMessages[updatedMessages.length - 1] = incomingChunk;
          }
          return ChatLoaded(
            messages: List.unmodifiable(updatedMessages),
            activeProvider: _activeProvider,
          );
        },
        onError: (error, stackTrace) {
          developer.log(
            'FAIL: Errore riscontrato durante lo streaming dei token nativi',
            name: 'ai_orchestrator.ChatBloc',
            error: error,
            stackTrace: stackTrace,
            level: 900,
          );
          return ChatError(message: error.toString());
        },
      );

      // 3. Trigger del caricamento finale dal Database a stream completato con successo
      if (!isClosed) {
        add(LoadMessagesEvent(sessionId: event.sessionId));
      }
    } catch (e, stackTrace) {
      developer.log(
        'CRITICAL: Eccezione non gestita nella pipeline di streaming di invio',
        name: 'ai_orchestrator.ChatBloc',
        error: e,
        stackTrace: stackTrace,
        level: 1000,
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
      developer.log(
        'CRITICAL: Eccezione durante la pulizia della cronologia (Prune)',
        name: 'ai_orchestrator.ChatBloc',
        error: e,
        stackTrace: stackTrace,
        level: 1000,
      );
      if (!isClosed) {
        emit(ChatError(message: e.toString()));
      }
    }
  }
}
