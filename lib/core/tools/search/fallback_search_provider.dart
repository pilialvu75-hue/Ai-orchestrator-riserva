import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/tools/search/search_provider.dart';

/// Tries a general Web provider first and falls back to a secondary provider
/// when the primary fails or returns no usable results.
final class FallbackSearchProvider implements SearchProvider {
  FallbackSearchProvider({
    required SearchProvider primary,
    required SearchProvider fallback,
  })  : _primary = primary,
        _fallback = fallback;

  final SearchProvider _primary;
  final SearchProvider _fallback;

  @override
  Duration get timeout => _primary.timeout + _fallback.timeout;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 5,
  }) async {
    Object? primaryError;

    try {
      final primaryResults = await _primary.search(query, limit: limit);
      if (primaryResults.isNotEmpty) {
        RuntimeEventLog.instance.emit(
          '[WEBSEARCH_PROVIDER_RESULT] route=primary '
          'results=${primaryResults.length}',
        );
        return primaryResults;
      }
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_PROVIDER_FALLBACK] reason=primary_empty',
      );
    } catch (error) {
      primaryError = error;
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_PROVIDER_FALLBACK] reason=primary_error error=$error',
      );
    }

    try {
      final fallbackResults = await _fallback.search(query, limit: limit);
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_PROVIDER_RESULT] route=fallback '
        'results=${fallbackResults.length}',
      );
      return fallbackResults;
    } catch (fallbackError) {
      RuntimeEventLog.instance.emit(
        '[WEBSEARCH_PROVIDER_FAILURE] primary_error=${primaryError ?? 'none'} '
        'fallback_error=$fallbackError',
      );
      if (primaryError != null) {
        throw StateError(
          'Both search providers failed. Primary: $primaryError; '
          'fallback: $fallbackError',
        );
      }
      rethrow;
    }
  }
}
