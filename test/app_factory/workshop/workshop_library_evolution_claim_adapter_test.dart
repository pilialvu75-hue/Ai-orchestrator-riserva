import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_claim_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const adapter = WorkshopLibraryEvolutionClaimAdapter();

  test('Library claim becomes isolated Cantiere evolution task', () {
    final task = adapter.fromJson(_claim());

    expect(task.id, 'library-evolution:evo-a18f2c13c19927904ced0bbd');
    expect(task.kind, WorkshopTaskKind.codeModification);
    expect(task.tags, containsAll(<String>['researcher-v2', 'module-evolution']));
    expect(task.fileScope.allowed, <String>['candidate_workspace/**']);
    expect(task.fileScope.forbidden, contains('stable_library/**'));
    expect(task.metadata['capabilityId'], 'ai.acceleration_backend');
    expect(task.metadata['sourceCodeTransferred'], isFalse);
    expect(task.metadata['claimSource'], 'library_evolution_queue');
    expect(task.acceptanceCriteria.map((item) => item.id), contains('implementation_tests_pass'));
    expect(task.isAgentReady, isTrue);
  });

  test('claim from non-Library source fails closed', () {
    final claim = _claim()..['source'] = 'researcher_direct';
    expect(
      () => adapter.fromJson(claim),
      throwsA(
        isA<WorkshopLibraryEvolutionClaimException>()
            .having((error) => error.code, 'code', 'invalid-source'),
      ),
    );
  });

  test('unsafe mutation policy fails closed', () {
    final claim = _claim()..['mutation_policy'] = 'mutate_library';
    expect(
      () => adapter.fromJson(claim),
      throwsA(
        isA<WorkshopLibraryEvolutionClaimException>()
            .having((error) => error.code, 'code', 'unsafe-mutation-policy'),
      ),
    );
  });
  test('claim with incomplete acceptance gates fails closed', () {
    final claim = _claim();
    (claim['acceptance_gates'] as List<String>).removeLast();
    expect(
      () => adapter.fromJson(claim),
      throwsA(isA<WorkshopLibraryEvolutionClaimException>()
          .having((error) => error.code, 'code', 'invalid-acceptance-gates')),
    );
  });

  test('claim with unexpected acceptance gate fails closed', () {
    final claim = _claim();
    (claim['acceptance_gates'] as List<String>).add('untrusted_gate');
    expect(
      () => adapter.fromJson(claim),
      throwsA(isA<WorkshopLibraryEvolutionClaimException>()
          .having((error) => error.code, 'code', 'invalid-acceptance-gates')),
    );
  });

  test('claim with invalid required output fails closed', () {
    final claim = _claim();
    (claim['required_output'] as Map<String, dynamic>)['status'] = 'active';
    expect(
      () => adapter.fromJson(claim),
      throwsA(isA<WorkshopLibraryEvolutionClaimException>()
          .having((error) => error.code, 'code', 'invalid-required-output')),
    );
  });

  test('claim carrying executable payload fields fails closed', () {
    for (final field in <String>[
      'source_code',
      'files',
      'payload',
      'patch',
      'diff',
      'commands',
    ]) {
      final claim = _claim()..[field] = 'untrusted';
      expect(
        () => adapter.fromJson(claim),
        throwsA(isA<WorkshopLibraryEvolutionClaimException>().having(
          (error) => error.code,
          'code',
          'forbidden-executable-field-$field',
        )),
        reason: field,
      );
    }
  });
}

Map<String, dynamic> _claim() => <String, dynamic>{
      'schema': 'ai-orchestrator.evolution-cantiere-claim.v1',
      'source': 'library_evolution_queue',
      'work_id': 'evo-a18f2c13c19927904ced0bbd',
      'proposal_id':
          '46d3210c343113b4c5831284dcc3f1ff78add85561f6a06c636bcd1883a1553d',
      'capability_id': 'ai.acceleration_backend',
      'objective':
          'Evaluate and implement only the useful capability delta.',
      'knowledge_delta': <String>['practice:readme_present'],
      'acceptance_gates': <String>[
        'implementation_tests_pass',
        'security_gates_pass',
        'regression_tests_pass',
        'library_contract_pass',
      ],
      'mutation_policy': 'isolated_candidate_no_library_mutation',
      'required_output': <String, dynamic>{
        'type': 'library_intake_bundle',
        'status': 'discovered',
        'path_scope': 'intake/<asset>/<version>',
      },
    };
