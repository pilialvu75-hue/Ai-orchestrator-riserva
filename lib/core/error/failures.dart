import 'package:equatable/equatable.dart';

/// Base class for all domain-layer failures.
abstract class Failure extends Equatable {
  const Failure([this.message = '']);

  final String message;

  @override
  List<Object> get props => [message];
}

/// Failure originating from a local database operation.
class DatabaseFailure extends Failure {
  const DatabaseFailure([super.message]);
}

/// Failure originating from a remote API call (OpenAI / Gemini).
class ServerFailure extends Failure {
  const ServerFailure([super.message]);
}

/// Failure when the device has no network connection.
class NetworkFailure extends Failure {
  const NetworkFailure([super.message]);
}

/// Failure when a requested entity cannot be found.
class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message]);
}

/// Failure when a provided value is invalid.
class ValidationFailure extends Failure {
  const ValidationFailure([super.message]);
}

/// Failure when an Android Intent operation fails.
class IntentFailure extends Failure {
  const IntentFailure([super.message]);
}

/// Failure when a file download operation fails.
class DownloadFailure extends Failure {
  const DownloadFailure([super.message]);
}

/// Failure when a required device permission is denied.
class PermissionFailure extends Failure {
  const PermissionFailure([super.message]);
}
