import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/usecase_failure_mapper.dart';

class SendChatMessage implements UseCase<ChatMessage, SendChatMessageParams> {
  const SendChatMessage(this.repository);

  final ChatRepository repository;

  @override
  Future<Either<Failure, ChatMessage>> call(
      SendChatMessageParams params) async {
    try {
      final message = await repository.sendMessage(
        sessionId: params.sessionId,
        userPrompt: params.userPrompt,
        systemPrompt: params.systemPrompt,
      );
      return Right(message);
    } catch (error) {
      return Left(
        mapUsecaseFailure(
          error,
          fallbackFactory: (message) => ServerFailure(message),
        ),
      );
    }
  }
}

class SendChatMessageParams extends Equatable {
  const SendChatMessageParams({
    required this.sessionId,
    required this.userPrompt,
    this.systemPrompt,
  });

  final String sessionId;
  final String userPrompt;
  final String? systemPrompt;

  @override
  List<Object?> get props => [sessionId, userPrompt, systemPrompt];
}
