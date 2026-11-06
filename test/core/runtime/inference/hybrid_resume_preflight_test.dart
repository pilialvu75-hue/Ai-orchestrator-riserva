import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_progress_checkpoint_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_resume_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage implements HybridCloudConsentStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
  @override
  Future<void> delete(String key) async { data.remove(key); }
}

void main() {
  late HybridProgressCheckpointJournal journal;
  late HybridResumePreflight preflight;
  var allow = true;
  var instructions = <String>['cloud first', 'local second', 'cloud third'];
  final evidence = <int, String>{1: 'verified first', 2: 'verified second'};
  var loadCalls = 0;

  setUp(() async {
    allow = true;
    instructions = <String>['cloud first', 'local second', 'cloud third'];
    evidence..clear()..addAll(<int, String>{1:'verified first',2:'verified second'});
    loadCalls = 0;
    journal = HybridProgressCheckpointJournal(
      storage: _Storage(),
      authorizeOwnerSession: (owner, session) async =>
          allow && owner == 'owner1' && session == 'chat1',
    );
    await journal.begin(
      ownerId: 'owner1', sessionId: 'chat1',
      taskId: 'task1', totalSteps: 3);
    preflight = HybridResumePreflight(
      journal: journal,
      loadPlan: (o,s,t) async {
        loadCalls++;
        return instructions;
      },
      loadEvidence: (o,s,t,n) async => evidence[n],
    );
  });

  Future<HybridResumePreview> inspect() => preflight.inspect(
    ownerId:'owner1', sessionId:'chat1', taskId:'task1');

  Future<void> complete(HybridCheckpointExecutor executor, int revision) async {
    await journal.completeStep(
      ownerId:'owner1', sessionId:'chat1', taskId:'task1',
      expectedRevision:revision, executor:executor);
  }

  test('H49c only previews explicitly verified next step', () async {
    await complete(HybridCheckpointExecutor.cloud, 0);
    await complete(HybridCheckpointExecutor.local, 1);
    final preview = await inspect();
    expect(preview.completedSteps, 2);
    expect(preview.revision, 2);
    expect(preview.verifiedResults, ['verified first', 'verified second']);
    expect(preview.nextInstruction, 'cloud third');
    expect(() => preview.verifiedResults.add('forged'), throwsUnsupportedError);
    expect(loadCalls, 1);
  });

  test('H49c missing receipt fails closed instead of skipping steps', () async {
    await complete(HybridCheckpointExecutor.cloud, 0);
    await complete(HybridCheckpointExecutor.local, 1);
    evidence.remove(1);
    await expectLater(inspect(), throwsStateError);
  });

  test('H49c plan mismatch, revocation, and completed state', () async {
    instructions = ['one', 'two'];
    await expectLater(inspect(), throwsStateError);
    instructions = ['one','two','three'];
    allow = false;
    await expectLater(inspect(), throwsStateError);
    allow = true;
    await complete(HybridCheckpointExecutor.cloud, 0);
    await complete(HybridCheckpointExecutor.local, 1);
    await complete(HybridCheckpointExecutor.cloud, 2);
    evidence[3] = 'verified third';
    final preview = await inspect();
    expect(preview.isComplete, isTrue);
    expect(preview.nextInstruction, isNull);
  });

  test('H49c changed progress during review is rejected', () async {
    var triggered = false;
    final racing = HybridResumePreflight(
      journal: journal,
      loadPlan: (o,s,t) async => instructions,
      loadEvidence: (o,s,t,n) async {
        if (!triggered) {
          triggered = true;
          await complete(HybridCheckpointExecutor.local, 1);
        }
        return evidence[n];
      },
    );
    await complete(HybridCheckpointExecutor.cloud, 0);
    await expectLater(
      racing.inspect(ownerId:'owner1', sessionId:'chat1', taskId:'task1'),
      throwsStateError,
    );
  });

  test('H49c preflight never starts inference or a Cloud request', () async {
    final preview = await inspect();
    expect(preview.completedSteps, 0);
    expect(preview.nextInstruction, 'cloud first');
    expect(evidence.length, 2);
  });
}
