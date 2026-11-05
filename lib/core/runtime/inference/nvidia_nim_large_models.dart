/// NVIDIA hosted prototype model identifiers shared by Aivexus/AI Orchestrator
/// Cloud and Hybrid. These are metadata only: they do NOT start inference,
/// install GGUF files, or grant credentials/consent/spending privileges.
///
/// Aivexus Web has a separate Cloudflare route catalogue and independent
/// credentials. It must not import or depend on this Flutter catalogue.
abstract final class NvidiaNimLargeModels {
  static const String nemotronUltra = 'nvidia/nemotron-3-ultra-550b-a55b';
  static const String kimiK26 = 'moonshotai/kimi-k2.6';
  static const String deepSeekV41Flash = 'deepseek-ai/deepseek-v4.1-flash';

  static const Map<String, String> labels = <String, String>{
    nemotronUltra: 'Nemotron 3 Ultra · 550B',
    kimiK26: 'Kimi K2.6 · 1T',
    deepSeekV41Flash: 'DeepSeek V4.1 Flash · 552B',
  };

  /// These hosted trial endpoints are not a permanent free production tier.
  /// Actual account entitlement must be tested; explicit user consent and
  /// cloud spending policy remain authoritative in Hybrid mode.
  static const List<String> prototypeOptions = <String>[
    nemotronUltra,
    kimiK26,
    deepSeekV41Flash,
  ];

  static bool isKnownPrototype(String modelId) =>
      labels.containsKey(modelId.trim());
}
