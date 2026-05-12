import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

class RuntimeSession {
  RuntimeSession({
    required this.sessionId,
    CancellationToken? cancellationToken,
  }) : cancellationToken = cancellationToken ?? CancellationToken();

  final String sessionId;
  final CancellationToken cancellationToken;
}
