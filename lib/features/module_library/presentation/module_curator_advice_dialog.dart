import 'package:ai_orchestrator/features/module_library/domain/module_curator_advice.dart';
import 'package:flutter/material.dart';

Future<void> showModuleCuratorAdviceDialog(
  BuildContext context, {
  required String title,
  required ModuleCuratorResult result,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .secondaryContainer
                      .withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Consiglio AI — solo consultivo. La Library deterministica '
                  'resta l’unica autorità per certificazione, sicurezza, '
                  'compatibilità e stato dei moduli.',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Provider: ${result.provider}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                result.aiCalled
                    ? 'Gemini è stato consultato.'
                    : 'Risposta deterministica: Gemini non è stato chiamato.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (result.recommendations.isEmpty)
                const Text('Nessun avviso o consiglio aggiuntivo.')
              else
                ...result.recommendations.map(
                  (recommendation) => _RecommendationCard(
                    recommendation: recommendation,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Chiudi'),
        ),
      ],
    ),
  );
}

Future<void> showModuleCuratorErrorDialog(
  BuildContext context,
  Object error,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome_outlined),
          SizedBox(width: 8),
          Expanded(child: Text('Curator AI non disponibile')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(error.toString()),
            const SizedBox(height: 12),
            const Text(
              'Lo stato e i conteggi della Module Library non vengono '
              'modificati da questo errore.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Chiudi'),
        ),
      ],
    ),
  );
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.recommendation});

  final ModuleCuratorRecommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final percent = (recommendation.confidence * 100).round();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _label(recommendation.type),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text('$percent%'),
              ],
            ),
            const SizedBox(height: 8),
            Text(recommendation.summary),
            if (recommendation.assetRefs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Moduli: ${recommendation.assetRefs.join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (recommendation.adapterSuggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Adapter suggeriti:'),
              ...recommendation.adapterSuggestions.map(
                (value) => Text('• $value'),
              ),
            ],
            if (recommendation.warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Attenzioni:'),
              ...recommendation.warnings.map(
                (value) => Text('• $value'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _label(String value) => switch (value) {
        'coverage_gap' => 'Copertura insufficiente',
        'candidate_ranking' => 'Confronto candidati',
        'reuse_recommendation' => 'Suggerimento di riuso',
        'duplicate_hint' => 'Possibile duplicato',
        'adapter_hint' => 'Suggerimento adapter',
        'health_warning' => 'Avviso salute modulo',
        _ => value,
      };
}
