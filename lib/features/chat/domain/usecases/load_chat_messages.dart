import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/usecase_failure_mapper.dart';

class LoadChatMessages
    implements UseCase<List<ChatMessage>, LoadChatMessagesParams> {
  const LoadChatMessages(this.repository);

  final ChatRepository repository;

  @override
  Future<Either<Failure, List<ChatMessage>>> call(
      LoadChatMessagesParams params) async {
    try {
      final messages = await repository.getMessages(params.sessionId);
      return Right(messages);
    } catch (error) {
      return Left(
        mapUsecaseFailure(
          error,
          fallbackFactory: (message) => DatabaseFailure(message),
        ),
      );
    }
  }
}

class LoadChatMessagesParams extends Equatable {
  const LoadChatMessagesParams({required this.sessionId});

  final String sessionId;

  @override
  List<Object?> get props => [sessionId];
}
