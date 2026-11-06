import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:http/http.dart' as http;

import 'hybrid_cloud_ai_request_seal.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_cloud_transport_unavailable.dart';

/// A deliberately opt-in and UNWIRED native HTTP sender for approved requests.
///
/// Uses the same AiRequestModel serializers as the existing OpenAI/Gemini
/// sources; no alternate prompt assembler, no automatic provider failover.
/// The one-shot permit is checked before the HTTP client starts. The
/// credential must have an explicit stable account ID and may not be an
/// unbound environment fallback. No production Chat path instantiates this.
///
/// This covers provider-neutral fields and native JSON for these TWO routes;
/// it does not cover provider SDK changes, attachments, tools, or other APIs.
final class HybridCloudNativeWireSender {
  const HybridCloudNativeWireSender({
    required HybridCloudDisclosureConsent consent,
    required CloudCredentialStore credentials,
    required http.Client client,
  })  : _consent = consent,
        _credentials = credentials,
        _client = client;

  final HybridCloudDisclosureConsent _consent;
  final CloudCredentialStore _credentials;
  final http.Client _client;

  Future<http.Response> send({
    required HybridCloudAiRequestSeal seal,
    required HybridCloudDispatchPermit permit,
    required String expectedCredentialSecret,
    CancellationToken? cancellationToken,
  }) => seal.dispatch<http.Response>(
        isRequestActive: cancellationToken == null
            ? null
            : () => !cancellationToken.isCancelled,
        consent: _consent,
        permit: permit,
        isCurrentDestination: (providerId, accountId) async {
          if (providerId != 'openAi' && providerId != 'gemini') {
            return false;
          }
          final current = _credentials.snapshotFor(providerId);
          return current.configured &&
              _credentials.consentBindingFor(providerId) ==
                  seal.disclosure.credentialBindingId &&
              seal.disclosure.credentialBindingId != null &&
              !current.isExpired &&
              !current.fromEnvironmentFallback &&
              current.accountId == accountId &&
              accountId.isNotEmpty;
        },
        trustedSend: (AiRequest approved) async {
          final providerId = approved.providerId;
          if (providerId == null ||
              (providerId != 'openAi' && providerId != 'gemini')) {
            throw StateError('Unsupported consent-gated Cloud provider');
          }
          if (providerId != seal.disclosure.providerId) {
            throw StateError('Cloud destination does not match the consent');
          }
          final current = _credentials.snapshotFor(providerId);
          final apiKey = _credentials.secretFor(providerId);
          if (!current.configured ||
              current.isExpired ||
              current.fromEnvironmentFallback ||
              current.accountId == null ||
              current.accountId != seal.disclosure.accountId ||
              seal.disclosure.credentialBindingId == null ||
              _credentials.consentBindingFor(providerId) !=
                  seal.disclosure.credentialBindingId ||
              apiKey == null ||
              apiKey.isEmpty ||
              expectedCredentialSecret.isEmpty ||
              apiKey != expectedCredentialSecret) {
            throw StateError('Cloud credential changed before sending');
          }
          final selectedModel = approved.modelId;
          if (selectedModel == null ||
              selectedModel.length > 120 ||
              !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$')
                  .hasMatch(selectedModel)) {
            throw StateError('Untrusted Cloud model identifier');
          }
          if (approved.tools.isNotEmpty || approved.metadata.isNotEmpty) {
            throw StateError('Unclassified tools or metadata');
          }

          // This is the exact model conversion used by the actual
          // OpenAiDataSource/GeminiDataSource. No hidden chat lookup occurs.
          final native = AiRequestModel.fromEntity(approved);
          late final Uri endpoint;
          late final Map<String, String> headers;
          late final String body;
          if (providerId == 'openAi') {
            endpoint = Uri.parse(
                AppConstants.openAiBaseUrl + '/chat/completions');
            headers = <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + apiKey,
            };
            body = jsonEncode(native.toOpenAiJson(model: selectedModel));
          } else {
            endpoint = Uri.parse(
                AppConstants.geminiBaseUrl + '/models/' +
                Uri.encodeComponent(selectedModel) + ':generateContent');
            headers = <String, String>{
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            };
            body = jsonEncode(native.toGeminiJson(model: selectedModel));
          }
          // POST starts under the in-isolate one-use consent gate. It is
          // released for concurrent revocation once the request starts.
          try {
            return await _client.post(endpoint, headers: headers, body: body);
          } on http.ClientException {
            // Only approved HTTP failures get a typed network cause.
            // Never leak provider URI, prompt, exception body or credentials.
            throw const HybridCloudTransportUnavailable();
          } on TimeoutException {
            throw const HybridCloudTransportUnavailable();
          }
        },
      );
}
