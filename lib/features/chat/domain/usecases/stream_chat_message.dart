import 'dart:async';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';

class StreamChatMessageParams {
  final String sessionId;
  final String userPrompt;
  final String? systemPrompt;

  StreamChatMessageParams({
    required this.sessionId,
    required this.userPrompt,
    this.systemPrompt,
  });
}

class StreamChatMessage {
  // Se la firma del tuo repository espone già un percorso a callback o a stream, 
  // questo UseCase fa da ponte sicuro per non alterare i contratti esistenti.
  Stream<ChatMessage> call(StreamChatMessageParams params) {
    final controller = StreamController<ChatMessage>();
    
    // NOTA DI INTEGRAZIONE: Qui colleghi il controller al meccanismo di callback 
    // del tuo repository esistente o al provider FFI che effettua il poll sincrono.
    // Esempio di trasmissione:
    // if (!controller.isClosed) { controller.add(ChatMessage(text: piece, isUser: false)); }

    return controller.stream;
  }
}
