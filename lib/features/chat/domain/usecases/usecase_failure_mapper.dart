import 'package:ai_orchestrator/core/error/failures.dart';

Failure mapUsecaseFailure(
  Object error, {
  required Failure Function(String message) fallbackFactory,
}) {
  if (error is Failure) return error;
  return fallbackFactory(error.toString());
}
