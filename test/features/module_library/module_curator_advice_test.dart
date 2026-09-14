import 'package:ai_orchestrator/features/module_library/domain/module_curator_advice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> validResult() => <String, Object?>{
        'schema': ModuleCuratorResult.schema,
        'provider': 'gemini:gemini-3.6-flash',
        'advice': <String, Object?>{
          'recommendations': <Object?>[
            <String, Object?>{
              'type': 'coverage_gap',
              'confidence': 0.92,
              'summary': 'Manca una seconda implementazione certificata.',
              'asset_refs': <String>[],
              'capability_ids': <String>['storage.local_db'],
              'adapter_suggestions': <String>[],
              'warnings': <String>['Copertura incompleta.'],
              'ranking_factors': <Object?>[],
            },
          ],
        },
        'core_verification': <String, Object?>{
          'passed': true,
          'advisory_only': true,
          'library_mutated': false,
          'authority': 'deterministic-library-core',
          'ai_called': true,
        },
      };

  test('accepts only deterministically verified advisory results', () {
    final result = ModuleCuratorResult.fromJson(validResult());

    expect(result.provider, 'gemini:gemini-3.6-flash');
    expect(result.aiCalled, isTrue);
    expect(result.hasAdvice, isTrue);
    expect(result.recommendations.single.type, 'coverage_gap');
    expect(result.recommendations.single.confidence, 0.92);
  });

  test('rejects a result when Library mutation was reported', () {
    final json = validResult();
    final verification = Map<String, Object?>.from(
      json['core_verification']! as Map,
    );
    verification['library_mutated'] = true;
    json['core_verification'] = verification;

    expect(
      () => ModuleCuratorResult.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a result without deterministic authority', () {
    final json = validResult();
    final verification = Map<String, Object?>.from(
      json['core_verification']! as Map,
    );
    verification['authority'] = 'gemini';
    json['core_verification'] = verification;

    expect(
      () => ModuleCuratorResult.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });
}
