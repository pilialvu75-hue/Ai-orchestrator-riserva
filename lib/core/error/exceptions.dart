/// Exception thrown when a local database operation fails.
class DatabaseException implements Exception {
  const DatabaseException([this.message = 'Database error occurred']);

  final String message;

  @override
  String toString() => 'DatabaseException: $message';
}

/// Exception thrown when a remote API call fails.
class ServerException implements Exception {
  const ServerException([this.message = 'Server error occurred']);

  final String message;

  @override
  String toString() => 'ServerException: $message';
}

/// Exception thrown when there is no network connectivity.
class NetworkException implements Exception {
  const NetworkException([this.message = 'No network connection']);

  final String message;

  @override
  String toString() => 'NetworkException: $message';
}

/// Exception thrown when an entity is not found.
class NotFoundException implements Exception {
  const NotFoundException([this.message = 'Entity not found']);

  final String message;

  @override
  String toString() => 'NotFoundException: $message';
}

/// Exception thrown when an Android Intent operation fails.
class IntentException implements Exception {
  const IntentException([this.message = 'Android Intent error']);

  final String message;

  @override
  String toString() => 'IntentException: $message';
}

/// Exception thrown when a file download fails.
class DownloadException implements Exception {
  const DownloadException([this.message = 'Download error occurred']);

  final String message;

  @override
  String toString() => 'DownloadException: $message';
}

/// Exception thrown when a required device permission is denied.
class PermissionException implements Exception {
  const PermissionException([this.message = 'Permission denied']);

  final String message;

  @override
  String toString() => 'PermissionException: $message';
}
