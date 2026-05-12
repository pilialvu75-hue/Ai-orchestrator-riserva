import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_response.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/repositories/ai_repository.dart';

/// Sends a query to the active AI provider and returns the response.
class SendAiQuery implements UseCase<AiResponse, SendAiQueryParams> {
  const SendAiQuery(this.repository);

  final AiRepository repository;

  @override
  Future<Either<Failure, AiResponse>> call(SendAiQueryParams params) =>
      repository.sendQuery(params.request);
}

class SendAiQueryParams extends Equatable {
  const SendAiQueryParams({required this.request});

  final AiRequest request;

  @override
  List<Object?> get props => [request];
}
