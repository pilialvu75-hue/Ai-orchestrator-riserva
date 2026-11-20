import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_immutable_step_plan_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_local_continuation_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_local_step_coordinator.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_protected_resume_adapter.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_semantic_step_evidence_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _ProtectedStorage implements HybridCloudConsentStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

final class _ChatInference extends Mock implements InferenceService {
  final requests = <InferenceRequest>[];
  bool fail = false;

  @override
  TokenStream stream(InferenceRequest request) async* {
    requests.add(request);
    if (fail) {
      yield InferenceResponse.error('LOCAL failed');
      return;
    }
    yield InferenceResponse.token(text: 'verified', model: 'local-model');
    yield InferenceResponse.finalChunk(
      text: 'verified', tokensGenerated: 1, model: 'local-model');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HybridLocalContinuationService service;
  late HybridProgressCheckpointJournal journal;
  late HybridSemanticStepEvidenceStore evidence;
  late _ChatInference inference;
  var authorized = true;

  setUp(() async {
    authorized = true;
    final storage = _ProtectedStorage();
    journal = HybridProgressCheckpointJournal(
      storage: storage,
      authorizeOwnerSession: (owner, session) async =>
          authorized && owner == 'owner' && session == 'chat',
    );
    final plans = HybridImmutableStepPlanStore(
        storage: storage, journal: journal);
    evidence = HybridSemanticStepEvidenceStore(
        storage: storage, journal: journal);
    await journal.begin(
        ownerId: 'owner', sessionId: 'chat', taskId: 'task', totalSteps: 2);
    await plans.save(
      ownerId: 'owner', sessionId: 'chat', taskId: 'task',
      plan: HybridImmutableStepPlan(['First instruction', 'Second instruction']),
    );
    inference = _ChatInference();
    service = HybridLocalContinuationService(
      inference: inference,
      coordinator: HybridLocalStepCoordinator(
        resume: HybridProtectedResumeAdapter(
            journal: journal, plans: plans, evidence: evidence),
        journal: journal,
        evidence: evidence,
      ),
    );
  });

  Future<HybridProgressCheckpoint> run({
    Future<bool> Function(HybridVerifiedStepResult)? validate,
  }) => service.continueOneLocal(
    ownerId: 'owner', sessionId: 'chat', taskId: 'task',
    validateResult: validate ?? (_) async => true,
  );

  test('H52 commits one verified step using real Chat inference contract', () async {
    final first = await run();
    expect(first.completedSteps, 1);
    expect(first.lastExecutor, HybridCheckpointExecutor.local);
    expect(inference.requests.single.routeDirective,
        InferenceRouteDirective.localOnly);
    expect(inference.requests.single.isOffline, isTrue);
    expect(inference.requests.single.allowWebSearchTool, isFalse);
    expect(inference.requests.single.allowCloudProviderFailover, isFalse);
    expect(inference.requests.single.prompt, 'First instruction');
    final second = await run();
    expect(second.status, HybridCheckpointStatus.completed);
    expect(inference.requests.last.prompt, contains('Completed step 1: verified'));
    expect(inference.requests.last.prompt, contains('Second instruction'));
    expect((await evidence.loadCompletedStep(
        ownerId: 'owner', sessionId: 'chat', taskId: 'task', step: 2))?.output,
        'verified');
    await expectLater(run(), throwsStateError);
    expect(inference.requests, hasLength(2));
  });

  test('H52 never commits failed or unverified LOCAL output', () async {
    inference.fail = true;
    await expectLater(run(), throwsStateError);
    expect((await journal.load(
        ownerId: 'owner', sessionId: 'chat', taskId: 'task'))!.completedSteps, 0);
    inference.fail = false;
    await expectLater(run(validate: (_) async => false), throwsStateError);
    expect((await journal.load(
        ownerId: 'owner', sessionId: 'chat', taskId: 'task'))!.completedSteps, 0);
  });

  test('H52 denies unauthorized owner before starting inference', () async {
    authorized = false;
    await expectLater(run(), throwsStateError);
    expect(inference.requests, isEmpty);
  });
}
