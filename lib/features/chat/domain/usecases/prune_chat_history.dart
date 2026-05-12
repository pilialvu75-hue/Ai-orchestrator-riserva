import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/usecase_failure_mapper.dart';

class PruneChatHistory implements UseCase<int, PruneChatHistoryParams> {
  const PruneChatHistory(this.repository);

  final ChatRepository repository;

  @override
  Future<Either<Failure, int>> call(PruneChatHistoryParams params) async {
    try {
      final deleted = await repository.pruneHistory(
        maxAgeDays: params.maxAgeDays,
        maxRows: params.maxRows,
      );
      return Right(deleted);
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

class PruneChatHistoryParams extends Equatable {
  const PruneChatHistoryParams({
    this.maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    this.maxRows = AppConstants.chatHistoryMaxRows,
  });

  final int maxAgeDays;
  final int maxRows;

  @override
  List<Object?> get props => [maxAgeDays, maxRows];
}
