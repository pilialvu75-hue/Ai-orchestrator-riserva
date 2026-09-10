import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';

enum CloudProviderCapability {
  general,
  reasoning,
  coding,
  tools,
  multimodal,
  longContext,
}

enum CloudProviderCostClass {
  freeTier,
  paid,
  unknown,
}

/// Describes why a provider can currently participate in a free-first route.
///
/// This is intentionally separate from [CloudProviderCostClass]. The router
/// only needs to know whether automatic use is spend-safe, while Settings and
/// diagnostics need to distinguish durable free tiers from development grants,
/// account-dependent access and temporary promotional credit.
enum CloudProviderAccessClass {
  recurringFreeTier,
  developmentPrototypeFreeAccess,
  accountDependentFreeAccess,
  promoCredit,
  paid,
  unknown,
}

class CloudProviderDefinition {
  const CloudProviderDefinition({
    required this.id,
    required this.displayName,
    required this.defaultModel,
    required this.capabilities,
    required this.costClass,
    required this.accessClass,
    this.supportsApiKey = true,
    this.supportsOAuth = false,
    this.isCustom = false,
  });

  final String id;
  final String displayName;
  final String defaultModel;
  final Set<CloudProviderCapability> capabilities;
  final CloudProviderCostClass costClass;
  final CloudProviderAccessClass accessClass;
  final bool supportsApiKey;
  final bool supportsOAuth;
  final bool isCustom;

  bool supports(CloudProviderCapability capability) =>
      capabilities.contains(capability);
}

/// Canonical Cloud provider registry.
///
/// Built-in providers remain compile-time definitions. User-created provider
/// profiles are projected into the same read-only contract at runtime, so
/// routing/settings do not need new code whenever a compatible provider is
/// added later.
class CloudProviderCatalog {
  CloudProviderCatalog._();

  static const Map<String, CloudProviderDefinition> _builtInDefinitions =
      <String, CloudProviderDefinition>{
    'openAi': CloudProviderDefinition(
      id: 'openAi',
      displayName: 'OpenAI',
      defaultModel: 'gpt-5.6-terra',
      costClass: CloudProviderCostClass.paid,
      accessClass: CloudProviderAccessClass.paid,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.multimodal,
        CloudProviderCapability.longContext,
      },
    ),
    'gemini': CloudProviderDefinition(
      id: 'gemini',
      displayName: 'Gemini',
      defaultModel: 'gemini-3.8-flash',
      costClass: CloudProviderCostClass.freeTier,
      accessClass: CloudProviderAccessClass.recurringFreeTier,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.multimodal,
        CloudProviderCapability.longContext,
      },
      supportsOAuth: true,
    ),
    'claude': CloudProviderDefinition(
      id: 'claude',
      displayName: 'Claude',
      defaultModel: 'claude-sonnet-5',
      costClass: CloudProviderCostClass.paid,
      accessClass: CloudProviderAccessClass.paid,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.multimodal,
        CloudProviderCapability.longContext,
      },
    ),
    'grok': CloudProviderDefinition(
      id: 'grok',
      displayName: 'Grok',
      defaultModel: 'grok-4.6',
      costClass: CloudProviderCostClass.paid,
      accessClass: CloudProviderAccessClass.paid,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.multimodal,
        CloudProviderCapability.longContext,
      },
    ),
    'copilot': CloudProviderDefinition(
      id: 'copilot',
      displayName: 'GitHub Copilot',
      defaultModel: 'gpt-5.6-terra',
      costClass: CloudProviderCostClass.unknown,
      accessClass: CloudProviderAccessClass.unknown,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.longContext,
      },
      supportsOAuth: true,
    ),
    'groq': CloudProviderDefinition(
      id: 'groq',
      displayName: 'Groq',
      defaultModel: 'qwen/qwen3.8-27b',
      costClass: CloudProviderCostClass.freeTier,
      accessClass: CloudProviderAccessClass.recurringFreeTier,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.longContext,
      },
    ),
    'nvidiaNim': CloudProviderDefinition(
      id: 'nvidiaNim',
      displayName: 'NVIDIA NIM',
      defaultModel: 'meta/llama-3.1-8b-instruct',
      costClass: CloudProviderCostClass.freeTier,
      accessClass: CloudProviderAccessClass.developmentPrototypeFreeAccess,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.longContext,
      },
    ),
    'mistral': CloudProviderDefinition(
      id: 'mistral',
      displayName: 'Mistral',
      defaultModel: 'mistral-small-latest',
      costClass: CloudProviderCostClass.freeTier,
      accessClass: CloudProviderAccessClass.accountDependentFreeAccess,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.longContext,
      },
    ),
    'openRouter': CloudProviderDefinition(
      id: 'openRouter',
      displayName: 'OpenRouter Free Pool',
      defaultModel: 'openrouter/free',
      costClass: CloudProviderCostClass.freeTier,
      accessClass: CloudProviderAccessClass.accountDependentFreeAccess,
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.longContext,
      },
    ),
  };

  static Map<String, CloudProviderDefinition> get definitions {
    final result = <String, CloudProviderDefinition>{
      ..._builtInDefinitions,
    };
    for (final profile in CustomCloudProviderStore.instance.profiles) {
      result[profile.id] = _fromCustom(profile);
    }
    return Map<String, CloudProviderDefinition>.unmodifiable(result);
  }

  static List<String> get supportedProviders =>
      List<String>.unmodifiable(definitions.keys);

  static bool isBuiltIn(String providerId) =>
      _builtInDefinitions.containsKey(providerId);

  static bool isCustom(String providerId) =>
      CustomCloudProviderStore.instance.contains(providerId);

  static CloudProviderDefinition? definitionFor(String providerId) {
    final builtIn = _builtInDefinitions[providerId];
    if (builtIn != null) return builtIn;
    final custom = CustomCloudProviderStore.instance.profileFor(providerId);
    return custom == null ? null : _fromCustom(custom);
  }

  static String defaultModelFor(String providerId) =>
      definitionFor(providerId)?.defaultModel ?? '';

  static CloudProviderCostClass costClassFor(String providerId) =>
      definitionFor(providerId)?.costClass ?? CloudProviderCostClass.unknown;

  static CloudProviderAccessClass accessClassFor(String providerId) =>
      definitionFor(providerId)?.accessClass ?? CloudProviderAccessClass.unknown;

  static bool supports(
    String providerId,
    CloudProviderCapability capability,
  ) =>
      definitionFor(providerId)?.supports(capability) ?? false;

  static CloudProviderDefinition _fromCustom(
    CustomCloudProviderProfile profile,
  ) {
    final free = profile.billing == CustomCloudProviderBilling.free;
    return CloudProviderDefinition(
      id: profile.id,
      displayName: profile.displayName,
      defaultModel: profile.defaultModel,
      costClass:
          free ? CloudProviderCostClass.freeTier : CloudProviderCostClass.paid,
      accessClass: free
          ? CloudProviderAccessClass.recurringFreeTier
          : CloudProviderAccessClass.paid,
      isCustom: true,
      capabilities: const <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.longContext,
      },
    );
  }

  /// Compatibility ordering for older callers. New routing code must score
  /// concrete executor state instead of treating these lists as fixed policy.
  static const List<String> codingPriority = <String>[
    'groq',
    'gemini',
    'nvidiaNim',
    'mistral',
    'openRouter',
    'claude',
    'openAi',
    'grok',
    'copilot',
  ];

  static const List<String> reasoningPriority = <String>[
    'gemini',
    'groq',
    'nvidiaNim',
    'mistral',
    'openRouter',
    'claude',
    'openAi',
    'grok',
    'copilot',
  ];

  static const List<String> generalPriority = <String>[
    'gemini',
    'groq',
    'mistral',
    'openRouter',
    'nvidiaNim',
    'openAi',
    'claude',
    'grok',
    'copilot',
  ];
}
