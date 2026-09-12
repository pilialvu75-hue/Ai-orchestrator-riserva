import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Emits a deliberately small, closed diagnostic vocabulary for Cloud routing.
///
/// No prompt, response, model, credential, endpoint, session identifier or
/// custom-provider identifier is ever written by this helper. Public export can
/// therefore validate the complete event instead of trying to redact free text.
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
