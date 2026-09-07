enum CloudProviderCapability {
  general,
  reasoning,
  coding,
  tools,
  multimodal,
  longContext,
}

class CloudProviderDefinition {
  const CloudProviderDefinition({
    required this.id,
    required this.displayName,
    required this.defaultModel,
    required this.capabilities,
    this.supportsApiKey = true,
    this.supportsOAuth = false,
  });

  final String id;
  final String displayName;
  final String defaultModel;
  final Set<CloudProviderCapability> capabilities;
  final bool supportsApiKey;
  final bool supportsOAuth;

  bool supports(CloudProviderCapability capability) =>
      capabilities.contains(capability);
}

/// Canonical Cloud provider registry.
///
/// The catalog contains provider metadata and capabilities only. It does not
/// decide which provider must execute a task; routing belongs to the runtime
/// router and can additionally consider health, quota, budget and user policy.
class CloudProviderCatalog {
  CloudProviderCatalog._();

  static const Map<String, CloudProviderDefinition> definitions =
      <String, CloudProviderDefinition>{
    'openAi': CloudProviderDefinition(
      id: 'openAi',
      displayName: 'OpenAI',
      defaultModel: 'gpt-5.6-terra',
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

  static const List<String> supportedProviders = <String>[
    'openAi',
    'gemini',
    'claude',
    'grok',
    'copilot',
  ];

  static CloudProviderDefinition? definitionFor(String providerId) =>
      definitions[providerId];

  static String defaultModelFor(String providerId) =>
      definitions[providerId]?.defaultModel ?? '';

  static bool supports(
    String providerId,
    CloudProviderCapability capability,
  ) =>
      definitions[providerId]?.supports(capability) ?? false;

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
