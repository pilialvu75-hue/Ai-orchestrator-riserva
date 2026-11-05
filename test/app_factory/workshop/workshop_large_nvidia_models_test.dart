import 'dart:io';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/nvidia_nim_large_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('both large NVIDIA prototype models are recognized', () {
    expect(NvidiaNimLargeModels.kimiK26, 'moonshotai/kimi-k2.6');
    expect(NvidiaNimLargeModels.deepSeekV41Flash,
        'deepseek-ai/deepseek-v4.1-flash');
    expect(NvidiaNimLargeModels.prototypeOptions, hasLength(3));

    for (final modelId in <String>[
      NvidiaNimLargeModels.kimiK26,
      NvidiaNimLargeModels.deepSeekV41Flash,
    ]) {
      expect(NvidiaNimLargeModels.isKnownPrototype(modelId), isTrue);
      final model = WorkshopModelCatalogue.findById(modelId);
      expect(model, isNotNull);
      expect(model!.source, AiModelSource.cloud);
      expect(model.cloudProviderId, 'nvidiaNim');
      expect(model.optional, isTrue);
      expect(model.downloadUrl, isEmpty);
      expect(model.sizeBytes, 0);
      for (final role in <AppAiRole>[
        AppAiRole.workshopOrchestrator,
        AppAiRole.architect,
        AppAiRole.engineer,
        AppAiRole.reviewer,
      ]) {
        expect(model.canServe(role), isTrue);
        expect(
          WorkshopModelCatalogue.forRole(role).map((value) => value.id),
          contains(modelId),
        );
      }
    }
    expect(WorkshopModelCatalogue.forRole(AppAiRole.assistantOrchestrator),
        isEmpty);
  });

  test('Hybrid Cloud provider retains opt-in trial spending classification', () {
    expect(CloudProviderCatalog.defaultModelFor('nvidiaNim'),
        NvidiaNimLargeModels.nemotronUltra);
    expect(CloudProviderCatalog.accessClassFor('nvidiaNim'),
        CloudProviderAccessClass.developmentPrototypeFreeAccess);
    expect(CloudProviderCatalog.costClassFor('nvidiaNim'),
        CloudProviderCostClass.unknown);
  });

  test('Web broker excludes manual-only models from AUTO and preserves secrets',
      () {
    final broker = File('functions/api/cantiere/inference.js').readAsStringSync();
    final catalog = File('functions/api/cantiere/models.js').readAsStringSync();
    final enrollment =
        File('scripts/airlab/web_p0_enroll_large_nim_models.mjs')
            .readAsStringSync();

    expect(broker, contains('manualOnly: row.manualOnly === true'));
    expect(broker, contains('(!route.manualOnly || hasSelectedRoute)'));
    expect(broker, contains('route.selfTestFree'));
    expect(catalog, contains('manualOnly: row.manualOnly === true'));
    for (final modelId in <String>[
      NvidiaNimLargeModels.kimiK26,
      NvidiaNimLargeModels.deepSeekV41Flash,
    ]) {
      expect(enrollment, contains(modelId));
    }
    expect(enrollment, contains('manualOnly: true'));
    expect(enrollment, contains('selfTestFree: true'));
    expect(enrollment, contains('_READ_ONLY_PREFLIGHT_PASS'));
    expect(enrollment, contains('_ROLLBACK_ATTEMPTED'));
  });
}
