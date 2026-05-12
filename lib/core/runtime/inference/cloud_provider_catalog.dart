class CloudProviderCatalog {
  CloudProviderCatalog._();

  static const List<String> supportedProviders = <String>[
    'openAi',
    'gemini',
    'claude',
    'grok',
    'copilot',
  ];

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
