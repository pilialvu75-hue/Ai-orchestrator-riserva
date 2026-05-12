class RuntimeStageException implements Exception {
  RuntimeStageException({
    required this.stage,
    required this.message,
    this.details,
  });

  final String stage;
  final String message;
  final String? details;

  String toPayload() {
    final hasDetails = details != null && details!.trim().isNotEmpty;
    return !hasDetails
        ? 'AI_RUNTIME_ERROR|stage=$stage|message=$message'
        : 'AI_RUNTIME_ERROR|stage=$stage|message=$message|details=$details';
  }

  String toLogMessage() {
    final hasDetails = details != null && details!.trim().isNotEmpty;
    return !hasDetails ? message : '$message ($details)';
  }

  @override
  String toString() => toPayload();
}
