import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Emits a deliberately small, closed diagnostic vocabulary for Cloud routing.
///
/// No prompt, raw response, model identifier, credential, endpoint, session
/// identifier or custom-provider identifier is ever written by this helper.
/// Only a fixed model class and categorized HTTP metadata may be exported.
final class CloudRoutingDiagnostics {
  CloudRoutingDiagnostics._();

  static const Set<String> _taskTypes = <String>{
    'general',
    'reasoning',
    'coding',
  };

  static void attempt({
    required String providerId,
    required String? taskType,
  }) {
    _emit(
      providerId: providerId,
      taskType: taskType,
      decision: 'attempt',
      reason: 'dispatch',
    );
  }

  static void success({
    required String providerId,
    required String? taskType,
  }) {
    _emit(
      providerId: providerId,
      taskType: taskType,
      decision: 'success',
      reason: 'completed',
    );
  }

  static void failure({
    required String providerId,
    required String? taskType,
    required Object failure,
  }) {
    _emit(
      providerId: providerId,
      taskType: taskType,
      decision: 'failure',
      reason: _failureReason(failure),
    );
  }

  /// A strictly closed receipt for a real HTTP error, not an internal
  /// cooldown/preflight denial. Never emits responseBody or modelId directly.
  static void httpFailure({
    required String providerId,
    required String? modelId,
    required int statusCode,
    required Duration? retryAfter,
    required String responseBody,
  }) {
    final provider = _safeProvider(providerId);
    final status =
        statusCode >= 400 && statusCode <= 599 ? '$statusCode' : 'none';
    final modelClass = providerId.trim() == 'mistral'
        ? switch (modelId?.trim().toLowerCase()) {
            'mistral-small-latest' => 'small',
            'mistral-large-4' => 'large4',
            _ => 'other',
          }
        : 'other';
    final retrySeconds = retryAfter?.inSeconds;
    final retry = retrySeconds != null &&
            retrySeconds >= 0 &&
            retrySeconds <= 86400
        ? '$retrySeconds'
        : 'none';

    // Error text is *only* examined for closed, non-identifying categories.
    // A hint is not authoritative; 'unknown' is safer than guessing.
    final body = responseBody.toLowerCase();
    final hint = body.contains('requests per second') ||
            body.contains('request per second') ||
            body.contains('rps')
        ? 'rps'
        : body.contains('tokens per minute') ||
                body.contains('token per minute') ||
                body.contains('tpm')
            ? 'tpm'
            : body.contains('requests per minute') || body.contains('rpm')
                ? 'rpm'
                : body.contains('monthly') || body.contains('per month')
                    ? 'monthly'
                    : body.contains('quota') ||
                            body.contains('credit') ||
                            body.contains('insufficient') ||
                            body.contains('budget')
                        ? 'quota'
                        : body.contains('free tier') ||
                                body.contains('subscription tier')
                            ? 'tier'
                            : 'unknown';

    RuntimeEventLog.instance.emit(
      '[CLOUD_HTTP_FAILURE] provider=$provider status=$status '
      'model_class=$modelClass retry_after_s=$retry limit_hint=$hint',
    );
  }

  static String _safeTask(String? taskType) {
    final normalized = taskType?.trim();
    return _taskTypes.contains(normalized) ? normalized! : 'general';
  }

  static String _safeProvider(String providerId) {
    final normalized = providerId.trim();
    return CloudProviderCatalog.isBuiltIn(normalized) ? normalized : 'custom';
  }

  static String _failureReason(Object failure) {
    if (failure is CloudFailure) {
      return switch (failure.kind) {
        CloudFailureKind.authentication => 'authentication',
        CloudFailureKind.rateLimit => 'rate_limit',
        CloudFailureKind.quota => 'quota',
        CloudFailureKind.providerUnavailable => 'provider_unavailable',
        CloudFailureKind.network => 'network',
        CloudFailureKind.timeout => 'timeout',
        CloudFailureKind.incompleteOutput => 'incomplete_output',
        CloudFailureKind.emptyOutput => 'empty_output',
        CloudFailureKind.unsupported => 'unsupported',
        CloudFailureKind.other => 'other',
      };
    }

    // Compatibility fallback for legacy callers that have not migrated to a
    // structured CloudFailure yet.
    final text = failure.toString().toLowerCase();
    if (text.contains('429') || text.contains('rate limit')) {
      return 'rate_limit';
    }
    if (text.contains('quota') ||
        text.contains('credit') ||
        text.contains('insufficient')) {
      return 'quota';
    }
    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('auth') ||
        text.contains('api key') ||
        text.contains('not configured')) {
      return 'authentication';
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return 'timeout';
    }
    if (text.contains('network') ||
        text.contains('socket') ||
        text.contains('connection')) {
      return 'network';
    }
    if (text.contains('unsupported') || text.contains('not supported')) {
      return 'unsupported';
    }
    if (text.contains('unavailable')) {
      return 'provider_unavailable';
    }
    return 'other';
  }

  static void _emit({
    required String providerId,
    required String? taskType,
    required String decision,
    required String reason,
  }) {
    final provider = _safeProvider(providerId);
    final task = _safeTask(taskType);
    final cost = CloudProviderCatalog.costClassFor(providerId).name;

    RuntimeEventLog.instance.emit(
      '[CLOUD_ROUTING] '
      'task=$task cost=$cost provider=$provider '
      'decision=$decision reason=$reason',
    );
  }
}
