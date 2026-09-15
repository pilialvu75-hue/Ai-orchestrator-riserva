import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_reader.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_verification.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

final class WorkshopWebClaimCandidate {
  const WorkshopWebClaimCandidate({
    required this.statement,
    required this.kind,
    this.requiresFreshness = false,
  });

  final String statement;
  final WorkshopWebClaimKind kind;
  final bool requiresFreshness;
}

/// Semantic boundary that extracts only project-relevant claims from already
/// opened Web documents.
///
/// Production may use a Workshop role inference adapter; tests can remain fully
/// deterministic. Implementations must return an empty list rather than invent
/// claims when extraction is uncertain or malformed.
abstract interface class WorkshopWebClaimExtractor {
  Future<List<WorkshopWebClaimCandidate>> extract({
    required WorkshopRequest request,
    required WorkshopWebSourceReadPack sourcePack,
    required bool isOffline,
    CancellationToken? cancellationToken,
  });
}

/// Classifies one opened source against one claim.
///
/// The classifier performs semantic interpretation only. Final truth/usage
/// decisions remain in [WorkshopWebVerificationPolicy].
abstract interface class WorkshopWebObservationClassifier {
  Future<WorkshopWebSourceObservation?> classify({
    required WorkshopWebClaimCandidate claim,
    required WorkshopWebResearchSource source,
    required Uri finalUrl,
    required String pageText,
    required bool isOffline,
    CancellationToken? cancellationToken,
  });
}

final class WorkshopWebVerificationPack {
  const WorkshopWebVerificationPack({
    this.attempted = false,
    this.verifications = const <WorkshopWebClaimVerification>[],
  });

  final bool attempted;
  final List<WorkshopWebClaimVerification> verifications;

  bool get hasVerifiedClaims => verifications.any((entry) => entry.isVerified);
  bool get hasDisputes => verifications.any(
        (entry) => entry.status == WorkshopWebVerificationStatus.disputed,
      );
  bool get needsMoreEvidence =>
      verifications.any((entry) => entry.needsCorroboration);

  String toPromptContext() {
    if (verifications.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln('WORKSHOP WEB VERIFICATION — CLAIM-LEVEL EVIDENCE')
      ..writeln(
        'Treat VERIFIED factual claims as corroborated evidence. SUPPORTED '
        'claims still require caution when they affect implementation. '
        'DISPUTED/INSUFFICIENT claims are unresolved and must not be silently '
        'treated as facts. SUBJECTIVE signals describe observed preferences, '
        'not universal truth. Licensing is verified only from explicit primary '
        'reuse terms.',
      );

    for (final item in verifications) {
      buffer
        ..writeln()
        ..writeln('CLAIM: ${item.claim}')
        ..writeln('KIND: ${item.kind.name}')
        ..writeln('STATUS: ${item.status.name}')
        ..writeln('EVIDENCE_STRENGTH: ${item.evidenceStrength.toStringAsFixed(2)}')
        ..writeln('NEEDS_CORROBORATION: ${item.needsCorroboration}')
        ..writeln('REASON: ${item.reason}');
    }

    return buffer.toString().trimRight();
  }
}

/// Retrieves independent evidence for a claim and turns opened pages into
/// source observations. It never decides the final verification status.
final class WorkshopWebClaimCorroborator {
  const WorkshopWebClaimCorroborator({
    required Tool webSearchTool,
    required WorkshopPublicWebPageFetcher fetcher,
    required WorkshopWebObservationClassifier classifier,
    this.maxSearchResults = 4,
    this.maxCorroborationPages = 2,
    this.maxClassifierChars = 2600,
  })  : assert(maxSearchResults > 0),
        assert(maxCorroborationPages > 0),
        assert(maxClassifierChars > 0),
        _webSearchTool = webSearchTool,
        _fetcher = fetcher,
        _classifier = classifier;

  final Tool _webSearchTool;
  final WorkshopPublicWebPageFetcher _fetcher;
  final WorkshopWebObservationClassifier _classifier;
  final int maxSearchResults;
  final int maxCorroborationPages;
  final int maxClassifierChars;

  Future<List<WorkshopWebSourceObservation>> corroborate({
    required WorkshopWebClaimCandidate claim,
    required WorkshopWebSourceReadPack sourcePack,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    final observations = <WorkshopWebSourceObservation>[];
    final seenHosts = <String>{};

    for (final document in sourcePack.documents) {
      if (_cancelled(cancellationToken)) break;
      final host = _normalizedHost(document.finalUrl.host);
      if (host.isNotEmpty) seenHosts.add(host);
      final observation = await _classify(
        claim: claim,
        source: document.source,
        finalUrl: document.finalUrl,
        text: document.text,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
      if (observation != null) observations.add(observation);
    }

    if (isOffline || _cancelled(cancellationToken)) {
      return List<WorkshopWebSourceObservation>.unmodifiable(observations);
    }

    ToolResult searchResult;
    try {
      searchResult = await _webSearchTool.execute(<String, dynamic>{
        'query': claim.statement,
        'limit': maxSearchResults,
      });
    } catch (error) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_WEB_VERIFY] kind=${claim.kind.name} '
        'status=search_failed error_type=${error.runtimeType}',
      );
      return List<WorkshopWebSourceObservation>.unmodifiable(observations);
    }

    if (!searchResult.success) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_WEB_VERIFY] kind=${claim.kind.name} '
        'status=search_unavailable '
        'failure_reason=${_metadataString(searchResult.metadata['failure_reason'])}',
      );
      return List<WorkshopWebSourceObservation>.unmodifiable(observations);
    }

    final candidates = _sources(searchResult.metadata['results']);
    var opened = 0;
    for (final source in candidates) {
      if (_cancelled(cancellationToken) || opened >= maxCorroborationPages) {
        break;
      }

      final parsed = Uri.tryParse(source.url.trim());
      if (parsed == null) continue;
      final host = _normalizedHost(parsed.host);
      if (host.isEmpty || seenHosts.contains(host)) continue;

      final fetched = await _fetcher.fetch(source.url, isOffline: false);
      if (!fetched.isSuccess || fetched.page == null) continue;
      final page = fetched.page!;
      final finalHost = _normalizedHost(page.url.host);
      if (finalHost.isEmpty || seenHosts.contains(finalHost)) continue;

      opened += 1;
      seenHosts.add(finalHost);
      final observation = await _classify(
        claim: claim,
        source: source,
        finalUrl: page.url,
        text: page.text,
        isOffline: false,
        cancellationToken: cancellationToken,
      );
      if (observation != null) observations.add(observation);
    }

    return List<WorkshopWebSourceObservation>.unmodifiable(observations);
  }

  Future<WorkshopWebSourceObservation?> _classify({
    required WorkshopWebClaimCandidate claim,
    required WorkshopWebResearchSource source,
    required Uri finalUrl,
    required String text,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) {
    final bounded = _bounded(text.trim(), maxClassifierChars);
    if (bounded.isEmpty) return Future<WorkshopWebSourceObservation?>.value();
    return _classifier.classify(
      claim: claim,
      source: source,
      finalUrl: finalUrl,
      pageText: bounded,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }

  List<WorkshopWebResearchSource> _sources(Object? raw) {
    if (raw is! List) return const <WorkshopWebResearchSource>[];
    final result = <WorkshopWebResearchSource>[];
    for (final item in raw.take(maxSearchResults)) {
      if (item is! Map) continue;
      final url = _metadataString(item['url']);
      if (url.isEmpty) continue;
      result.add(
        WorkshopWebResearchSource(
          title: _metadataString(item['title']),
          url: url,
          snippet: _metadataString(item['snippet']),
        ),
      );
    }
    return result;
  }

  static bool _cancelled(CancellationToken? token) =>
      token?.isCancelled == true;

  static String _metadataString(Object? value) =>
      value is String ? value.trim() : '';

  static String _normalizedHost(String value) {
    final host = value.trim().toLowerCase();
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  static String _bounded(String value, int limit) {
    if (limit <= 0 || value.isEmpty) return '';
    if (value.length <= limit) return value;
    const marker = '\n[truncated]';
    if (limit <= marker.length) return value.substring(0, limit);
    return '${value.substring(0, limit - marker.length).trimRight()}$marker';
  }
}

/// Coordinates claim extraction, independent corroboration and deterministic
/// verification. This layer is read-only and never mutates the project.
final class WorkshopWebClaimVerificationCoordinator {
  const WorkshopWebClaimVerificationCoordinator({
    required WorkshopWebClaimExtractor extractor,
    required WorkshopWebClaimCorroborator corroborator,
    WorkshopWebVerificationPolicy policy = const WorkshopWebVerificationPolicy(),
    this.maxClaims = 3,
  })  : assert(maxClaims > 0),
        _extractor = extractor,
        _corroborator = corroborator,
        _policy = policy;

  final WorkshopWebClaimExtractor _extractor;
  final WorkshopWebClaimCorroborator _corroborator;
  final WorkshopWebVerificationPolicy _policy;
  final int maxClaims;

  Future<WorkshopWebVerificationPack> verify({
    required WorkshopRequest request,
    required WorkshopWebSourceReadPack sourcePack,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    if (!sourcePack.hasDocuments || _cancelled(cancellationToken)) {
      return const WorkshopWebVerificationPack();
    }

    List<WorkshopWebClaimCandidate> claims;
    try {
      claims = await _extractor.extract(
        request: request,
        sourcePack: sourcePack,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    } catch (error) {
      RuntimeEventLog.instance.emit(
        '[WORKSHOP_WEB_VERIFY] request=${request.id} '
        'status=claim_extraction_failed error_type=${error.runtimeType}',
      );
      return const WorkshopWebVerificationPack(attempted: true);
    }

    final verifications = <WorkshopWebClaimVerification>[];
    for (final claim in claims.take(maxClaims)) {
      if (_cancelled(cancellationToken)) break;
      final statement = claim.statement.trim();
      if (statement.isEmpty) continue;

      final observations = await _corroborator.corroborate(
        claim: claim,
        sourcePack: sourcePack,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
      final verification = _policy.evaluate(
        claim: statement,
        kind: claim.kind,
        observations: observations,
        requiresFreshness: claim.requiresFreshness,
      );
      verifications.add(verification);

      RuntimeEventLog.instance.emit(
        '[WORKSHOP_WEB_VERIFY] request=${request.id} '
        'kind=${claim.kind.name} status=${verification.status.name} '
        'observations=${observations.length} '
        'needs_corroboration=${verification.needsCorroboration}',
      );
    }

    return WorkshopWebVerificationPack(
      attempted: true,
      verifications: List<WorkshopWebClaimVerification>.unmodifiable(
        verifications,
      ),
    );
  }

  static bool _cancelled(CancellationToken? token) =>
      token?.isCancelled == true;
}
