import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:http/http.dart' as http;

import 'hybrid_cloud_approved_completion_sender.dart';
import 'hybrid_cloud_consent_denied.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_cloud_local_identity.dart';
import 'hybrid_cloud_native_request_projection.dart';
import 'hybrid_cloud_runtime_source_evidence.dart';
import 'hybrid_cloud_trusted_request_assembler.dart';

/// One exact provider request -> trusted source check -> opt-in UI approval ->
/// a one-use permit -> native OpenAI/Gemini HTTP. The legacy Cloud transport
/// does not appear in this chain.
///
/// Not enabled in ordinary Chat until that UI passes a trusted callback and
/// the Chat repository supplies provenance at its real assembly boundary.
/// Missing evidence, identity, account or dialog is a hard denial.
final class HybridCloudRuntimeConsentCoordinator {
  HybridCloudRuntimeConsentCoordinator({
    required HybridCloudDisclosureConsent consent,
    required HybridCloudLocalIdentity identity,
    required CloudCredentialStore credentials,
    required http.Client client,
    Future<HybridCloudRuntimeSourceEvidence?> Function(
      InferenceRequest request,
    )? evidenceFor,
    this.requestConsent,
  }) : _consent = consent,
       _identity = identity,
       _credentials = credentials,
       _client = client,
       _evidenceFor = evidenceFor ??
           ((request) async => request.trustedCloudSourceEvidence);

  final HybridCloudDisclosureConsent _consent;
  final HybridCloudLocalIdentity _identity;
  final CloudCredentialStore _credentials;
  final http.Client _client;
  final Future<HybridCloudRuntimeSourceEvidence?> Function(
    InferenceRequest request,
  ) _evidenceFor;
  final Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> Function(
    HybridCloudConsentReview review,
  )? requestConsent;

  Future<AiResponse> send(
    InferenceRequest source,
    AiRequest outbound,
    CancellationToken cancellationToken,
  ) async {
    if (cancellationToken.isCancelled) {
      throw const HybridCloudConsentDenied();
    }
    final providerId = outbound.providerId;
    if (providerId != 'openAi' && providerId != 'gemini') {
      throw const HybridCloudConsentDenied();
    }

    // Non-verified credentials, environment defaults and credentials without
    // a stable explicit account name can never inherit a previous approval.
    final account = _credentials.snapshotFor(providerId!);
    final accountId = account.accountId;
    if (!account.configured || account.isExpired ||
        account.fromEnvironmentFallback ||
        accountId == null || accountId.isEmpty) {
      throw const HybridCloudConsentDenied();
    }

    final evidence = await _evidenceFor(source);
    if (cancellationToken.isCancelled ||
        evidence == null || evidence.sessionId != source.sessionId) {
      throw const HybridCloudConsentDenied();
    }

    // The original runtime request is the trusted boundary, not its optimized
    // provider-facing history. No source may be invented after this snapshot.
    if (source.prompt.trim() != outbound.prompt ||
        source.systemPrompt != evidence.expectedSystemPrompt ||
        evidence.originalHistory.length != source.context.length) {
      throw const HybridCloudConsentDenied();
    }
    // The history originated from the local Chat store, not a model. The
    // existing Cloud optimizer may omit irrelevant, excluded or duplicate
    // turns, but it must never add, reorder or rewrite content.
    for (var i = 0; i < source.context.length; i++) {
      final turn = source.context[i];
      final message = evidence.originalHistory[i];
      if (turn.role.name != message.role.name ||
          turn.content != message.content) {
        throw const HybridCloudConsentDenied();
      }
    }
    var cursor = 0;
    for (final outgoing in outbound.messages) {
      var matched = false;
      while (cursor < source.context.length) {
        final candidate = source.context[cursor++];
        if (candidate.excludeFromContext) continue;
        if (candidate.role.name == outgoing.role.name &&
            candidate.content == outgoing.content) {
          matched = true;
          break;
        }
      }
      if (!matched) throw const HybridCloudConsentDenied();
    }

    final projected = HybridCloudNativeRequestProjection.project(outbound);
    final session = await _identity.openSession();
    if (cancellationToken.isCancelled ||
        !await _identity.isAuthorized(session.ownerId, session.sessionId)) {
      throw const HybridCloudConsentDenied();
    }

    // Check exact payload; any optimization, hidden tool result, unverified
    // history or provider rewrite fails closed rather than asking the user to
    // approve an incorrect preview.
    final seal = HybridCloudTrustedRequestAssembler.seal(
      ownerId: session.ownerId,
      sessionId: session.sessionId,
      accountId: accountId,
      purpose: 'Answer the current question using reviewed Cloud context',
      request: projected,
      originalQuestion: evidence.originalQuestion,
      exactBaseSystemPrompt: evidence.baseSystemPrompt,
      runtimeSystemPromptSuffix: evidence.runtimeSystemPromptSuffix,
      historySnapshot: List<AiMessage>.unmodifiable(outbound.messages),
      documentPrompt: evidence.documentPrompt,
      confirmedMemory: evidence.confirmedMemory,
    );
    final permit = await _consent.authorizeForDispatch(
      disclosure: seal.disclosure,
      requestConsent: requestConsent,
      isRequestActive: () => !cancellationToken.isCancelled,
    );
    if (permit == null || cancellationToken.isCancelled) {
      throw const HybridCloudConsentDenied();
    }

    return HybridCloudApprovedCompletionSender(
      consent: _consent,
      credentials: _credentials,
      client: _client,
    ).complete(
      seal: seal,
      permit: permit,
      cancellationToken: cancellationToken,
    );
  }
}
