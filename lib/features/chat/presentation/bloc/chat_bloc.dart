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

String initial Provider = 'openAi',

}):_activeProvider = initial Provider,

}

super(const ChatInitial()) {

on<LoadMessagesEvent>(_onLoadMessages);
on<SendMessageEvent>(_onSendMessage);

on<PruneHistoryEvent>(_onPruneHistory);

final StreamChatMessage streamChatMessage;

final LoadChatMessages loadChatMessages;

final PruneChatHistory pruneChatHistory;

final String_activeProvider;

List<ChatMessage>_messages = [];
Future<void>_onLoadMessages(

LoadMessagesEvent event, Emitter<ChatState> emit) async {

try {

emit(const ChatLoading());

final result = await loadChatMessages(

LoadChatMessagesParams(sessionld: event.sessionId));

if (isClosed) return;
result.fold(

(failure) {

developer.log(

'FAIL: Impossibile caricare i messaggi per la sessione \${event.sessionld}. Errore:

\${failure.message}',

},

);

name: 'ai_orchestrator. ChatBloc',

level: 900,

emit(ChatError(message: failure.message));

);

(messages) {

},

_messages = List<ChatMessage>.from(messages);
 emit(ChatLoaded(

messages: List.unmodifiable(_messages),

activeProvider: _activeProvider));

} catch (e, stackTrace) {

developer.log(

);
'CRITICAL: Eccezione non gestita durante il caricamento dei messaggi',

name: 'ai_orchestrator. ChatBloc',

error: e,

stackTrace: stackTrace,

level: 1000,

if (!isClosed) {

emit(ChatError(message: e.toString()));
}

}

}

Future<void>_onSendMessage(

SendMessageEvent event, Emitter<ChatState> emit) async {

try {

final now = DateTime.now().milliseconds Since Epoch;

final optimisticUserMessage = ChatMessage(

);
id: 'pending-user-\$now',

sessionld: event.sessionld,

role: 'user',

content: event.userPrompt,

timestamp: now,

attachments: event.attachments,

// Aggiorna immediatamente la lista locale con il messaggio dell'utente
 _messages.add(optimisticUserMessage);
final optimisticAssistant Message = ChatMessage(

);

id: 'pending-assistant-\$now',

sessionld: event.sessionld,

role: 'assistant',

content: ",

timestamp: now + 1,

provider: _activeProvider,

final should ShowAssistantPlaceholder =

event.userPrompt.trim().isNotEmpty || event.attachments.isEmpty;

emit(ChatSending(

messages: List.unmodifiable(<ChatMessage>[

]),

..._messages,

if (shouldShowAssistantPlaceholder) optimisticAssistant Message,

activeProvider: _activeProvider));

ChatMessage? lastAssistant Message;

await for (final assistant Message in streamChatMessage(
 StreamChatMessageParams(

sessionld: event.sessionld,

userPrompt: event.userPrompt,

systemPrompt: event.systemPrompt,

attachments: event.attachments,

activeProvider: _activeProvider,

),

)) {

if (isClosed) return;
lastAssistant Message = assistantMessage;

emit(ChatSending(

messages: List.unmodifiable(<ChatMessage>[

..._messages,

assistantMessage,

activeProvider: _activeProvider,

]).

));

}

// Consolida la risposta finale dell'assistente nella lista locale

if (lastAssistantMessage != null) {

}

_messages.add(lastAssistantMessage);
// Emette lo stato Loaded stabile prima di invocare il ricaricamento in background

if (!isClosed) {

}

emit(ChatLoaded(

));
messages: List.unmodifiable(_messages),

activeProvider: _activeProvider,

add(LoadMessages Event (sessionld: event.sessionld));

} catch (e, stackTrace) {

developer.log(

'CRITICAL: Unhandled exception in send streaming pipeline',
 name: 'ai_orchestrator. ChatBloc',

);

error: e,

stackTrace: stackTrace,

level: 1000,

if (!isClosed) {

emit(ChatError(message: e.toString()));

}

}

}

Future<void>_onPruneHistory(

}

PruneHistoryEvent event, Emitter<ChatState> emit) async {

try {

await pruneChatHistory(const Prune ChatHistoryParams());
} catch (e, stackTrace) {

}

developer.log(

}

'CRITICAL: Eccezione durante la pulizia della cronologia (Prune)',

);

name: 'ai_orchestrator.
ChatBloc',

error: e,

stackTrace: stackTrace,

level: 1000,

if (!isClosed) {

}

emit(ChatError(message: e.toString()));
}
