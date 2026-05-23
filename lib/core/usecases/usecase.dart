import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/core/error/failures.dart';

/// Contract for every use-case that requires a single typed [Params] input.
abstract class UseCase<T, Params> {
  Future<Either<Failure, T>> call(Params params);
}

/// Marker class for use-cases that need no parameters.
class NoParams extends Equatable {
  const NoParams();

  @override
  List<Object?> get props => [];
}
