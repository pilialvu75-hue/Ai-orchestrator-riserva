import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

import 'hybrid_cloud_ai_request_seal.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_cloud_native_wire_sender.dart';

/// Converts an exact, one-use approved native response into the app's AiResponse.
///
/// This is opt-in: no live Chat code instantiates it yet. The only outbound
/// HTTP operation still happens in HybridCloudNativeWireSender under its
/// account, payload and session checks. The caller supplies trusted source
/// classification and obtains explicit consent before calling [complete].
final class HybridCloudApprovedCompletionSender {
  const HybridCloudApprovedCompletionSender({
    required HybridCloudDisclosureConsent consent,
    required CloudCredentialStore credentials,
    required http.Client client,
  }) : _consent = consent,
       _credentials = credentials,
       _client = client;

  final HybridCloudDisclosureConsent _consent;
  final CloudCredentialStore _credentials;
  final http.Client _client;

  Future<AiResponse> complete({
    required HybridCloudAiRequestSeal seal,
    required HybridCloudDispatchPermit permit,
    required String expectedCredentialSecret,
    CancellationToken? cancellationToken,
  }) async {
    final response = await HybridCloudNativeWireSender(
      consent: _consent,
      credentials: _credentials,
      client: _client,
    ).send(
      seal: seal,
      permit: permit,
      expectedCredentialSecret: expectedCredentialSecret,
      cancellationToken: cancellationToken,
    );

    final provider = seal.disclosure.providerId;
    if (response.statusCode != 200) {
      // Provider errors can echo private content; do not propagate the body.
      final seconds = int.tryParse(response.headers['retry-after'] ?? '');
      throw CloudHttpException(
        provider: provider,
        statusCode: response.statusCode,
        message: 'Consent-gated Cloud request failed',
        retryAfter: seconds != null && seconds >= 0
            ? Duration(seconds: seconds)
            : null,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const FormatException('Invalid Cloud completion JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Cloud completion payload');
    }
    final AiResponseModel parsed = switch (provider) {
      'openAi' => AiResponseModel.fromOpenAiJson(decoded),
      'gemini' => AiResponseModel.fromGeminiJson(decoded),
      _ => throw StateError('Unsupported approved Cloud provider'),
    };
    if (parsed.text.trim().isEmpty) {
      throw const FormatException('Empty Cloud completion');
    }
    return parsed;
  }
}
