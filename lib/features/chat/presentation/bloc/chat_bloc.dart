import 'dart:developer' as developer;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required this.streamChatMessage,
    required this.loadChatMessages,
    required this.pruneChatHistory,
    String initialProvider = 'openAi',
  })  : _activeProvider = initialProvider,
        super(const ChatInitial()) {
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<EditMessageEvent>(_onEditMessage);
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
      final now = DateTime.now().millisecondsSinceEpoch;
      final optimisticUserMessage = ChatMessage(
        id: 'pending-user-$now',
        sessionId: event.sessionId,
        role: 'user',
        content: event.userPrompt,
        timestamp: now,
        attachments: event.attachments,
      );

      _messages.add(optimisticUserMessage);

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
            if (shouldShowAssistantPlaceholder) optimisticAssistantMessage,
          ]),
          activeProvider: _activeProvider));

      ChatMessage? lastAssistantMessage;

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
          messages: List.unmodifiable(<ChatMessage>[
            ..._messages,
            assistantMessage,
          ]),
          activeProvider: _activeProvider,
        ));
      }

      if (lastAssistantMessage != null) {
        _messages.add(lastAssistantMessage);
      }

      if (!isClosed) {
        emit(ChatLoaded(
          messages: List.unmodifiable(_messages),
          activeProvider: _activeProvider,
        ));

        add(LoadMessagesEvent(sessionId: event.sessionId));
      }
    } catch (e, stackTrace) {
      developer.log(
        'CRITICAL: Unhandled exception in send streaming pipeline',
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

  /// Gestisce la modifica di un messaggio utente esistente.
  ///
  /// 1. Trova il messaggio originale nella lista per ID.
  /// 2. Tronca _messages rimuovendo il messaggio originale e tutti
  ///    i messaggi successivi (incluse le risposte dell'assistente).
  /// 3. Dispatcha un nuovo SendMessageEvent con il testo modificato.
  Future<void> _onEditMessage(
      EditMessageEvent event, Emitter<ChatState> emit) async {
    try {
      developer.log(
        'EDIT: Modifica messaggio id=${event.originalMessageId} '
        'session=${event.sessionId} '
        'newChars=${event.newUserPrompt.length}',
        name: 'ai_orchestrator.ChatBloc',
      );

      final originalIndex = _messages.indexWhere(
        (m) => m.id == event.originalMessageId,
      );

      if (originalIndex == -1) {
        developer.log(
          'EDIT_WARN: messaggio ${event.originalMessageId} non trovato '
          'in _messages — tronco tutto e reinvio',
          name: 'ai_orchestrator.ChatBloc',
        );
        _messages.clear();
      } else {
        // Rimuove il messaggio originale e tutto ciò che viene dopo.
        _messages = _messages.sublist(0, originalIndex);
      }

      // Aggiorna la UI con la lista troncata prima della nuova risposta.
      if (!isClosed) {
        emit(ChatLoaded(
          messages: List.unmodifiable(_messages),
          activeProvider: _activeProvider,
        ));
      }

      // Reinvia come nuovo messaggio.
      add(SendMessageEvent(
        sessionId: event.sessionId,
        userPrompt: event.newUserPrompt,
        attachments: event.attachments,
      ));
    } catch (e, stackTrace) {
      developer.log(
        'CRITICAL: Eccezione durante la modifica del messaggio',
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
