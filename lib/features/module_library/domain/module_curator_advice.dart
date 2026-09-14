enum ModuleCuratorTask {
  coverage('coverage'),
  rankCandidates('rank_candidates'),
  findDuplicates('find_duplicates'),
  suggestAdapters('suggest_adapters'),
  healthReview('health_review');

  const ModuleCuratorTask(this.apiValue);

  final String apiValue;
}

final class ModuleCuratorRecommendation {
  const ModuleCuratorRecommendation({
    required this.type,
    required this.confidence,
    required this.summary,
    required this.assetRefs,
    required this.capabilityIds,
    required this.adapterSuggestions,
    required this.warnings,
  });

  final String type;
  final double confidence;
  final String summary;
  final List<String> assetRefs;
  final List<String> capabilityIds;
  final List<String> adapterSuggestions;
  final List<String> warnings;

  factory ModuleCuratorRecommendation.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    final confidence = json['confidence'];
    final summary = json['summary'];
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException('Tipo consiglio Curator non valido.');
    }
    if (confidence is! num || confidence < 0 || confidence > 1) {
      throw const FormatException('Confidenza Curator non valida.');
    }
    if (summary is! String || summary.trim().isEmpty) {
      throw const FormatException('Sintesi Curator non valida.');
    }
    return ModuleCuratorRecommendation(
      type: type.trim(),
      confidence: confidence.toDouble(),
      summary: summary.trim(),
      assetRefs: _stringList(json['asset_refs']),
      capabilityIds: _stringList(json['capability_ids']),
      adapterSuggestions: _stringList(json['adapter_suggestions']),
      warnings: _stringList(json['warnings']),
    );
  }

  static List<String> _stringList(Object? value) {
    if (value == null) return const <String>[];
    if (value is! List) {
      throw const FormatException('Lista Curator non valida.');
    }
    final result = <String>[];
    for (final item in value) {
      if (item is! String) {
        throw const FormatException('Voce Curator non valida.');
      }
      final normalized = item.trim();
      if (normalized.isNotEmpty) result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }
}

final class ModuleCuratorResult {
  const ModuleCuratorResult({
    required this.provider,
    required this.recommendations,
    required this.aiCalled,
  });

  static const String schema = 'ai-orchestrator.library-curator-result.v1';

  final String provider;
  final List<ModuleCuratorRecommendation> recommendations;
  final bool aiCalled;

  bool get hasAdvice => recommendations.isNotEmpty;

  factory ModuleCuratorResult.fromJson(Map<String, Object?> json) {
    if (json['schema'] != schema) {
      throw const FormatException('Schema risultato Curator non riconosciuto.');
    }

    final provider = json['provider'];
    if (provider is! String || provider.trim().isEmpty) {
      throw const FormatException('Provider Curator non valido.');
    }

    final verification = json['core_verification'];
    if (verification is! Map) {
      throw const FormatException('Verifica deterministica Curator mancante.');
    }
    final core = Map<String, Object?>.from(verification);
    if (core['passed'] != true ||
        core['advisory_only'] != true ||
        core['library_mutated'] != false ||
        core['authority'] != 'deterministic-library-core') {
      throw const FormatException(
        'Risultato Curator rifiutato: verifica deterministica non valida.',
      );
    }

    final advice = json['advice'];
    if (advice is! Map) {
      throw const FormatException('Consiglio Curator mancante.');
    }
    final recommendationsRaw = advice['recommendations'];
    if (recommendationsRaw is! List) {
      throw const FormatException('Raccomandazioni Curator non valide.');
    }
    final recommendations = <ModuleCuratorRecommendation>[];
    for (final item in recommendationsRaw) {
      if (item is! Map) {
        throw const FormatException('Raccomandazione Curator non valida.');
      }
      recommendations.add(
        ModuleCuratorRecommendation.fromJson(Map<String, Object?>.from(item)),
      );
    }

    return ModuleCuratorResult(
      provider: provider.trim(),
      recommendations: List<ModuleCuratorRecommendation>.unmodifiable(
        recommendations,
      ),
      aiCalled: core['ai_called'] == true,
    );
  }
}
