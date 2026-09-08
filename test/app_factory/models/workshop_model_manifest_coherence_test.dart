import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Workshop model catalogue matches shared download manifest', () async {
    final raw = await File('assets/models/manifest.json').readAsString();
    final manifest = jsonDecode(raw) as Map<String, dynamic>;

    for (final model in WorkshopModelCatalogue.workshopModels) {
      final rawEntry = manifest[model.id];

      expect(
        rawEntry,
        isA<Map<String, dynamic>>(),
        reason: '${model.id} must be supplied by the shared model manifest',
      );

      final entry = rawEntry! as Map<String, dynamic>;

      expect(
        entry['fileName'],
        model.filename,
        reason: '${model.id} filename drift would break shared downloads',
      );
      expect(
        entry['downloadUrl'],
        model.downloadUrl,
        reason: '${model.id} URL drift would route Workshop to a stale object',
      );
      expect(
        entry['sizeBytes'],
        model.sizeBytes,
        reason: '${model.id} size drift would make completion checks unreliable',
      );
    }
  });

  test('Workshop catalogue stays independent from Assistant-only models', () {
    expect(
      WorkshopModelCatalogue.workshopModels
          .map((model) => model.id)
          .contains(WorkshopModelCatalogue.assistantPhi35.id),
      isFalse,
    );
  });
}
