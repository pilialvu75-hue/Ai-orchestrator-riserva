import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_decision_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reusable asset stays hidden until the full preflight succeeds', () {
    final asset = WorkshopReusableAsset(
      id: 'verified-template',
      name: 'Verified template',
      kind: WorkshopReusableAssetKind.projectTemplate,
      origin: WorkshopReusableAssetOrigin.completedProject,
      description: 'Verified reusable Workshop source.',
      validationScore: 1,
    );
    final decision = WorkshopReuseDecision.reuse(
      WorkshopReuseMatch(
        asset: asset,
        score: 1,
        reasons: const <String>['verified-local-asset-match'],
      ),
    );

    final incomplete = WorkshopPreflightInferenceResult(
      analysis: _success('analysis complete'),
      architecture: const WorkshopInferenceResult(
        text: '',
        terminalState: InferenceTerminalState.timeout,
        errorMessage: 'planning timeout',
        runtimeNotice: 'AI_RUNTIME_ERROR|stage=stalled',
      ),
      reuseDecision: decision,
    );

    expect(incomplete.reusedLocalKnowledge, isTrue);
    expect(incomplete.readyForImplementation, isFalse);
    expect(incomplete.reusedAsset, isNull);

    final complete = WorkshopPreflightInferenceResult(
      analysis: _success('analysis complete'),
      architecture: _success('architecture complete'),
      reuseDecision: decision,
    );

    expect(complete.readyForImplementation, isTrue);
    expect(complete.reusedAsset, same(asset));
  });
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );
