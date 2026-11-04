import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:http/http.dart' as http;

import 'hybrid_cloud_approved_completion_sender.dart';
import 'hybrid_cloud_consent_denied.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_cloud_local_identity.dart';
import 'hybrid_cloud_native_request_projection.dart';
import 'hybrid_cloud_prompt_provenance.dart';
import 'hybrid_cloud_trusted_request_assembler.dart';

/// Provenance supplied by the application that originally assembled the Chat
/// turn. Neither an LLM nor a provider callback may synthesize this evidence.
///
/// Importantly, the original user question is separate from the RAG-augmented
/// inference prompt; they are *not* the same source of trust.
final class HybridCloudRuntimeSourceEvidence {
  HybridCloudRuntimeSourceEvidence({
    required this.sessionId,
    required this.originalQuestion,
    required this.baseSystemPrompt,
    required List<AiMessage> originalHistory,
    this.documentPrompt,
    this.confirmedMemory,
  }) : originalHistory = List<AiMessage>.unmodifiable(
          originalHistory.map((message) => AiMessage(
            role: message.role, content: message.content,
          )),
        );

  final String sessionId;
  final String originalQuestion;
  final String baseSystemPrompt;
  final List<AiMessage> originalHistory;
  final HybridCloudPromptProvenance? documentPrompt;
  final AssistantConfirmedMemoryContext? confirmedMemory;
}

/// One exact provider request -> trusted source check -> opt-in UI approval ->
/// a one-use permit -> native OpenAI/Gemini HTTP. The legacy Cloud transport
/// does not appear in this chain.
///
/// Not enabled in ordinary Chat until that UI passes a trusted callback and
/// the Chat repository supplies provenance at its real assembly boundary.
/// Missing evidence, identity, account or dialog is a hard denial.
final class HybridCloudRuntimeConsentCoordinator {
  const HybridCloudRuntimeConsentCoordinator({
    required HybridCloudDisclosureConsent consent,
    required HybridCloudLocalIdentity identity,
    required CloudCredentialStore credentials,
    required http.Client client,
    required Future<HybridCloudRuntimeSourceEvidence?> Function(
      InferenceRequest request,
    ) evidenceFor,
    this.requestConsent,
  }) : _consent = consent,
       _identity = identity,
       _credentials = credentials,
       _client = client,
       _evidenceFor = evidenceFor;

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
  ) async {
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
    if (evidence == null || evidence.sessionId != source.sessionId) {
      throw const HybridCloudConsentDenied();
    }

    // The original runtime request is the trusted boundary, not its optimized
    // provider-facing history. No source may be invented after this snapshot.
    if (source.prompt.trim() != outbound.prompt ||
        evidence.originalHistory.length != source.context.length) {
      throw const HybridCloudConsentDenied();
    }
    for (var i = 0; i < source.context.length; i++) {
      final item = source.context[i];
      final message = evidence.originalHistory[i];
      if (item.excludeFromContext ||
          item.role.name != message.role.name ||
          item.content != message.content) {
        throw const HybridCloudConsentDenied();
      }
    }

    final projected = HybridCloudNativeRequestProjection.project(outbound);
    final session = await _identity.openSession();
    if (!await _identity.isAuthorized(session.ownerId, session.sessionId)) {
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
      historySnapshot: evidence.originalHistory,
      documentPrompt: evidence.documentPrompt,
      confirmedMemory: evidence.confirmedMemory,
    );
    final permit = await _consent.authorizeForDispatch(
      disclosure: seal.disclosure,
      requestConsent: requestConsent,
    );
    if (permit == null) throw const HybridCloudConsentDenied();

    return HybridCloudApprovedCompletionSender(
      consent: _consent,
      credentials: _credentials,
      client: _client,
    ).complete(seal: seal, permit: permit);
  }
}
