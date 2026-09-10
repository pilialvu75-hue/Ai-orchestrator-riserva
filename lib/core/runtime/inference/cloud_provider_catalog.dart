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

class CloudProviderDefinition {
  const CloudProviderDefinition({
    required this.id,
    required this.displayName,
    required this.defaultModel,
    required this.capabilities,
    required this.costClass,
    this.supportsApiKey = true,
    this.supportsOAuth = false,
    this.isCustom = false,
  });

  final String id;
  final String displayName;
  final String defaultModel;
  final Set<CloudProviderCapability> capabilities;
  final CloudProviderCostClass costClass;
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
      capabilities: <CloudProviderCapability>{
        CloudProviderCapability.general,
        CloudProviderCapability.reasoning,
        CloudProviderCapability.coding,
        CloudProviderCapability.tools,
        CloudProviderCapability.longContext,
      },
      supportsOAuth: true,
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

  static bool supports(
    String providerId,
    CloudProviderCapability capability,
  ) =>
      definitionFor(providerId)?.supports(capability) ?? false;

  static CloudProviderDefinition _fromCustom(
    CustomCloudProviderProfile profile,
  ) {
    return CloudProviderDefinition(
      id: profile.id,
      displayName: profile.displayName,
      defaultModel: profile.defaultModel,
      costClass: profile.billing == CustomCloudProviderBilling.free
          ? CloudProviderCostClass.freeTier
          : CloudProviderCostClass.paid,
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
    'claude',
    'gemini',
    'openAi',
    'grok',
    'copilot',
  ];

  static const List<String> reasoningPriority = <String>[
    'gemini',
    'claude',
    'openAi',
    'grok',
    'copilot',
  ];

  static const List<String> generalPriority = <String>[
    'openAi',
    'gemini',
    'claude',
    'grok',
    'copilot',
  ];
}
