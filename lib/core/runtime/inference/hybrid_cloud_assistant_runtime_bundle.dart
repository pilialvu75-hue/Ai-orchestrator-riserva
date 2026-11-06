import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_local_identity.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_consent_coordinator.dart';
import 'package:http/http.dart' as http;

/// Assistant-only composition of the REAL opt-in review -> permit -> HTTP path.
///
/// The ordinary app CloudRuntimeProvider is deliberately not modified. Chat
/// must opt in at its own bootstrap; without a trusted live Chat review host,
/// source evidence or an explicit account-bound credential this fails closed.
/// Other AI providers remain available through the non-consent global runtime
/// but are never silently substituted inside the gated assistant request.
final class HybridCloudAssistantRuntimeBundle {
  HybridCloudAssistantRuntimeBundle._({
    required this.provider,
    required this.consent,
    required this.identity,
  });

  final CloudRuntimeProvider provider;
  final HybridCloudDisclosureConsent consent;
  final HybridCloudLocalIdentity identity;

  static const Set<String> _supportedWireProviders = <String>{
    'openAi',
    'gemini',
  };

  static HybridCloudAssistantRuntimeBundle create({
    required CloudCredentialStore credentials,
    required HybridCloudConsentStorage protectedStorage,
    required http.Client client,
    required List<String> Function() supportedProviders,
    required bool Function(String provider) isProviderAvailable,
    required String Function([String? providerName]) providerDisplayName,
    required HybridCloudChatReviewCallback chatReview,
    String? Function(String provider)? modelForProvider,
    String? Function()? preferredProvider,
    bool Function(String provider)? automaticUseAllowed,
    bool Function(String provider, CloudTaskClass task)?
        automaticUseAllowedForTask,
  }) {
    final identity = HybridCloudLocalIdentity(storage: protectedStorage);
    final consent = HybridCloudDisclosureConsent(
      backend: protectedStorage,
      authorizeOwnerSession: identity.isAuthorized,
    );
    final coordinator = HybridCloudRuntimeConsentCoordinator(
      consent: consent,
      identity: identity,
      credentials: credentials,
      client: client,
      chatReview: chatReview,
    );
    final provider = CloudRuntimeProvider(
      consentGated: true,
      // A second legacy Cloud transport is never an allowed fallback.
      sendQuery: (String _, AiRequest __) async {
        throw StateError('Unreviewed Cloud transport is unavailable to Chat');
      },
      consentGatedSend: coordinator.send,
      supportedProviders: () => supportedProviders()
          .where(_supportedWireProviders.contains)
          .toList(growable: false),
      isProviderAvailable: (provider) =>
          _supportedWireProviders.contains(provider) &&
          credentials.consentBindingFor(provider) != null &&
          isProviderAvailable(provider),
      providerDisplayName: providerDisplayName,
      modelForProvider: modelForProvider,
      preferredProvider: preferredProvider,
      automaticUseAllowed: automaticUseAllowed,
      automaticUseAllowedForTask: automaticUseAllowedForTask,
    );
    return HybridCloudAssistantRuntimeBundle._(
      provider: provider,
      consent: consent,
      identity: identity,
    );
  }
}
