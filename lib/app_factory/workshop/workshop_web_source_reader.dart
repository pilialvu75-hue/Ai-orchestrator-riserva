import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

final class WorkshopWebSourceDocument {
  const WorkshopWebSourceDocument({
    required this.lane,
    required this.source,
    required this.finalUrl,
    required this.contentType,
    required this.text,
    required this.bytesRead,
  });

  final WorkshopWebResearchLane lane;
  final WorkshopWebResearchSource source;
  final Uri finalUrl;
  final String contentType;
  final String text;
  final int bytesRead;

  String get sourceHost => finalUrl.host.trim().toLowerCase();
}

final class WorkshopWebSourceReadPack {
  const WorkshopWebSourceReadPack({
    this.attempted = false,
    this.documents = const <WorkshopWebSourceDocument>[],
    this.fetchAttempts = 0,
  });

  final bool attempted;
  final List<WorkshopWebSourceDocument> documents;
  final int fetchAttempts;

  bool get hasDocuments => documents.isNotEmpty;
  int get totalChars => documents.fold<int>(
        0,
        (total, document) => total + document.text.length,
      );
}

/// Opens a deliberately small, diverse subset of Cantiere Web-research
/// sources for deeper verification/understanding.
///
/// Search snippets remain sufficient for most product exploration. This reader
/// is intended for cases where page-level evidence materially improves a
/// decision. It therefore reads at most one successful document per research
/// lane, avoids reusing the same host across lanes when alternatives exist,
/// limits attempts, and maintains a separate prompt-sized character budget.
final class WorkshopWebSourceReader {
  const WorkshopWebSourceReader({
    required WorkshopPublicWebPageFetcher fetcher,
    this.maxDocuments = 3,
    this.maxAttemptsPerLane = 2,
    this.maxCharsPerDocument = 2200,
    this.maxTotalChars = 6000,
  })  : assert(maxDocuments > 0),
        assert(maxAttemptsPerLane > 0),
        assert(maxCharsPerDocument > 0),
        assert(maxTotalChars > 0),
        _fetcher = fetcher;

  final WorkshopPublicWebPageFetcher _fetcher;
  final int maxDocuments;
  final int maxAttemptsPerLane;
  final int maxCharsPerDocument;
  final int maxTotalChars;

  Future<WorkshopWebSourceReadPack> read({
    required WorkshopWebEvidencePack evidencePack,
    bool isOffline = false,
  }) async {
    if (isOffline || !evidencePack.hasEvidence) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_WEB_SOURCE_READ] status=skipped '
        'reason=${isOffline ? 'offline' : 'no_evidence'}',
      );
      return const WorkshopWebSourceReadPack();
    }

    final documents = <WorkshopWebSourceDocument>[];
    final usedHosts = <String>{};
    var remainingChars = maxTotalChars;
    var totalAttempts = 0;

    for (final laneEvidence in evidencePack.evidence) {
      if (documents.length >= maxDocuments || remainingChars <= 0) break;
      if (laneEvidence.sources.isEmpty) continue;

      var laneAttempts = 0;
      for (final source in laneEvidence.sources) {
        if (laneAttempts >= maxAttemptsPerLane ||
            documents.length >= maxDocuments ||
            remainingChars <= 0) {
          break;
        }

        final parsed = Uri.tryParse(source.url.trim());
        if (parsed == null || parsed.host.trim().isEmpty) continue;

        final host = _normalizedHost(parsed.host);
        if (host.isEmpty || usedHosts.contains(host)) continue;

        laneAttempts += 1;
        totalAttempts += 1;

        final result = await _fetcher.fetch(
          source.url,
          isOffline: isOffline,
        );
        if (!result.isSuccess || result.page == null) {
          RuntimeEventLog.instance.emit(
            '[WORKSHOP_WEB_SOURCE_READ] lane=${laneEvidence.lane.name} '
            'host=$host status=unavailable reason=${result.reason ?? result.status.name}',
          );
          continue;
        }

        final page = result.page!;
        final documentLimit = remainingChars < maxCharsPerDocument
            ? remainingChars
            : maxCharsPerDocument;
        final text = _bounded(page.text.trim(), documentLimit);
        if (text.isEmpty) continue;

        final finalHost = _normalizedHost(page.url.host);
        if (finalHost.isEmpty || usedHosts.contains(finalHost)) {
          continue;
        }

        documents.add(
          WorkshopWebSourceDocument(
            lane: laneEvidence.lane,
            source: source,
            finalUrl: page.url,
            contentType: page.contentType,
            text: text,
            bytesRead: page.bytesRead,
          ),
        );
        usedHosts.add(finalHost);
        remainingChars -= text.length;

        RuntimeEventLog.instance.emit(
          '[WORKSHOP_WEB_SOURCE_READ] lane=${laneEvidence.lane.name} '
          'host=$finalHost status=fetched chars=${text.length} '
          'remaining_budget_chars=$remainingChars',
        );
        break;
      }
    }

    return WorkshopWebSourceReadPack(
      attempted: totalAttempts > 0,
      documents: List<WorkshopWebSourceDocument>.unmodifiable(documents),
      fetchAttempts: totalAttempts,
    );
  }

  static String _normalizedHost(String value) {
    final host = value.trim().toLowerCase();
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  static String _bounded(String value, int limit) {
    if (limit <= 0 || value.isEmpty) return '';
    if (value.length <= limit) return value;

    const marker = '\n[truncated]';
    if (limit <= marker.length) return value.substring(0, limit);
    final bodyLimit = limit - marker.length;
    return '${value.substring(0, bodyLimit).trimRight()}$marker';
  }
}
