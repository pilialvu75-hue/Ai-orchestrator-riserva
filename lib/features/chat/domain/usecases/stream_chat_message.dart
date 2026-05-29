import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/usecase_failure_mapper.dart';

class StreamChatMessage {
  const StreamChatMessage(this.repository);

  final ChatRepository repository;

  Stream<ChatMessage> call(StreamChatMessageParams params) {
    late final StreamController<ChatMessage> controller;
    final emittedAt = DateTime.now().millisecondsSinceEpoch;
    final provisionalAssistantMessage = ChatMessage(
      id: 'pending-assistant-$emittedAt',
      sessionId: params.sessionId,
      role: 'assistant',
      content: '',
      timestamp: emittedAt,
      provider: params.activeProvider,
    );

    controller = StreamController<ChatMessage>(
      onListen: () async {
        try {
          final message = await repository.sendMessage(
            sessionId: params.sessionId,
            userPrompt: params.userPrompt,
            systemPrompt: params.systemPrompt,
            attachments: params.attachments,
            onPartialResponse: (partialText) {
              if (controller.isClosed || partialText.isEmpty) return;
              controller.add(
                provisionalAssistantMessage.copyWith(content: partialText),
              );
            },
          );
          if (!controller.isClosed) {
            controller.add(message);
          }
        } catch (error, stackTrace) {
          if (!controller.isClosed) {
            controller.addError(
              mapUsecaseFailure(
                error,
                fallbackFactory: (message) => ServerFailure(message),
              ),
              stackTrace,
            );
          }
        } finally {
          if (!controller.isClosed) {
            await controller.close();
          }
        }
      },
    );

    return controller.stream;
  }
}

class StreamChatMessageParams extends Equatable {
  const StreamChatMessageParams({
    required this.sessionId,
    required this.userPrompt,
    this.systemPrompt,
    this.attachments = const <ChatAttachment>[],
    this.activeProvider = 'openAi',
  });

  final String sessionId;
  final String userPrompt;
  final String? systemPrompt;
  final List<ChatAttachment> attachments;
  final String activeProvider;

  @override
  List<Object?> get props => [
        sessionId,
        userPrompt,
        systemPrompt,
        attachments,
        activeProvider,
      ];
}
