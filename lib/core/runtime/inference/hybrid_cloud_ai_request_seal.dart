import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';

import 'hybrid_cloud_disclosure_consent.dart';

/// Opt-in source-only bridge between the provider-neutral AiRequest contract
/// and a fully classified Cloud disclosure.
///
/// Every field that may influence a Cloud provider's input is represented in
/// the exact review fingerprint: controls, system instructions, structured
/// history and all parts of the user prompt (including RAG/attached extracts).
///
/// No automatic source/sensitivity classification is attempted here. A
/// trusted assembler MUST supply a scope for every section. Unsupported
/// metadata/tool payloads fail closed rather than being silently omitted.
/// The provider-specific HTTP adapter is NOT covered by this source-only
/// seal and must not add content after this boundary.
final class HybridCloudAiRequestSeal {
  HybridCloudAiRequestSeal._({
    required this.request,
    required this.disclosure,
  });

  final AiRequest request;
  final HybridCloudDisclosure disclosure;

  factory HybridCloudAiRequestSeal.fromRequest({
    required String ownerId,
    required String sessionId,
    required String accountId,
    required String purpose,
    required AiRequest request,
    required HybridDisclosureScope controlScope,
    required List<HybridDisclosureSegment> promptSegments,
    List<HybridDisclosureSegment> systemPromptSegments =
        const <HybridDisclosureSegment>[],
    required List<HybridDisclosureScope> historyScopes,
  }) {
    final providerId = request.providerId;
    if (providerId == null ||
        providerId.isEmpty ||
        request.modelId == null ||
        request.modelId!.trim().isEmpty ||
        request.tools.isNotEmpty ||
        request.metadata.isNotEmpty ||
        request.prompt.isEmpty ||
        !request.temperature.isFinite ||
        request.temperature < 0 ||
        request.temperature > 2 ||
        request.maxTokens <= 0 ||
        request.messages.length > 60 ||
        historyScopes.length != request.messages.length ||
        promptSegments.isEmpty ||
        promptSegments.map((part) => part.text).join() != request.prompt ||
        systemPromptSegments.map((part) => part.text).join() !=
            (request.systemPrompt ?? '')) {
      throw ArgumentError('Incomplete Cloud AiRequest classification');
    }

    // Copy into an immutable provider-neutral request: the original
    // messages list may be mutated while a consent dialog is displayed.
    final frozen = AiRequest(
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      temperature: request.temperature,
      maxTokens: request.maxTokens,
      messages: List<AiMessage>.unmodifiable(
        request.messages.map((message) => AiMessage(
              role: message.role,
              content: message.content,
            )),
      ),
      tools: const <Map<String, dynamic>>[],
      modelId: request.modelId,
      providerId: providerId,
      taskType: request.taskType,
      metadata: const <String, dynamic>{},
    );

    // A canonical, structured review representation; not native HTTP JSON.
    // Each segment includes a field label and stable ordinal to prevent a
    // silent switch of system/turn/prompt position using identical text.
    final classified = <HybridDisclosureSegment>[
      HybridDisclosureSegment(
        text: _record(<String, Object?>{
          'field': 'controls',
          'providerId': providerId,
          'modelId': frozen.modelId,
          'taskType': frozen.taskType,
          'temperature': frozen.temperature,
          'maxTokens': frozen.maxTokens,
          'tools': <Object>[],
          'metadata': <String, Object>{},
        }),
        scope: controlScope,
      ),
      for (var i = 0; i < systemPromptSegments.length; i++)
        HybridDisclosureSegment(
          text: _record(<String, Object?>{
            'field': 'systemPrompt',
            'part': i,
            'text': systemPromptSegments[i].text,
          }),
          scope: systemPromptSegments[i].scope,
        ),
      for (var i = 0; i < frozen.messages.length; i++)
        HybridDisclosureSegment(
          text: _record(<String, Object?>{
            'field': 'history',
            'index': i,
            'role': frozen.messages[i].role.name,
            'text': frozen.messages[i].content,
          }),
          scope: historyScopes[i],
        ),
      for (var i = 0; i < promptSegments.length; i++)
        HybridDisclosureSegment(
          text: _record(<String, Object?>{
            'field': 'prompt',
            'part': i,
            'text': promptSegments[i].text,
          }),
          scope: promptSegments[i].scope,
        ),
    ];

    final review = HybridCloudDisclosure(
      ownerId: ownerId,
      sessionId: sessionId,
      providerId: providerId,
      accountId: accountId,
      purpose: purpose,
      outboundText: classified.map((part) => part.text).join(),
      segments: classified,
    );
    return HybridCloudAiRequestSeal._(
      request: frozen,
      disclosure: review,
    );
  }

  static String _record(Map<String, Object?> value) =>
      jsonEncode(value) + '\n';

  /// Starts only a provider-neutral exact AiRequest snapshot. This is an
  /// experimental integration harness, NOT an app routing change and NOT a
  /// proof of native provider HTTP serialization.
  Future<T> dispatch<T>({
    required HybridCloudDisclosureConsent consent,
    required HybridCloudDispatchPermit permit,
    required Future<bool> Function(String providerId, String accountId)
        isCurrentDestination,
    required Future<T> Function(AiRequest exactRequest) trustedSend,
  }) => consent.dispatchApproved<T>(
        permit: permit,
        currentDisclosure: disclosure,
        isCurrentDestination: isCurrentDestination,
        trustedSend: (_) => trustedSend(request),
      );
}
