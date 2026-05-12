import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';

/// States emitted by [OrchestratorStateEngine].
abstract class ChatState extends Equatable {
  const ChatState();

  @override
  List<Object?> get props => [];
}

class ChatInitial extends ChatState {
  const ChatInitial();
}

class ChatLoading extends ChatState {
  const ChatLoading();
}

class ChatLoaded extends ChatState {
  const ChatLoaded({
    required this.messages,
    this.activeProvider = 'assistant',
    this.runtimeMessage,
    this.suggestOpeningSettings = false,
  });

  final List<ChatMessage> messages;
  final String activeProvider;
  final String? runtimeMessage;
  final bool suggestOpeningSettings;

  @override
  List<Object?> get props =>
      [messages, activeProvider, runtimeMessage, suggestOpeningSettings];
}

class ChatSending extends ChatState {
  const ChatSending({
    required this.messages,
    this.activeProvider = 'assistant',
    this.runtimeMessage,
  });

  final List<ChatMessage> messages;
  final String activeProvider;
  final String? runtimeMessage;

  @override
  List<Object?> get props => [messages, activeProvider, runtimeMessage];
}

class ChatError extends ChatState {
  const ChatError({required this.message});

  final String message;

  @override
  List<Object?> get props => [message];
}
