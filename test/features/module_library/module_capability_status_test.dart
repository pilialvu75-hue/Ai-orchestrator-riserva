import 'package:ai_orchestrator/features/module_library/domain/module_capability_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModuleCapabilityStatusProjector', () {
    test('reports complete and partial from active certified Library assets only', () {
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[
          _asset('voice.stt.a', 'voice.stt'),
          _asset('voice.stt.b', 'voice.stt'),
          _asset('voice.tts.a', 'voice.tts'),
        ]),
        researcherJson: _researcher(<Map<String, Object?>>[]),
      );

      final byId = {for (final row in rows) row.capabilityId: row};
      expect(byId['voice.stt']!.availability, ModuleCapabilityAvailability.complete);
      expect(byId['voice.stt']!.statusLabel, 'Completo 2/2');
      expect(byId['voice.stt']!.canReuse, isTrue);
      expect(byId['voice.tts']!.availability, ModuleCapabilityAvailability.partial);
      expect(byId['voice.tts']!.statusLabel, 'Parziale 1/2');
    });

    test('Researcher can mark searching but can never increase certified count', () {
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[]),
        researcherJson: _researcher(<Map<String, Object?>>[
          <String, Object?>{
            'capability_id': 'voice.stt',
            'research_state': 'SEARCHING',
            'candidate_count': 3,
            'qualified_candidates': 2,
            'shortlisted': 1,
            'submitted': 1,
            'security_review': 1,
            'security_blocked': 0,
          },
        ]),
      );

      final stt = rows.firstWhere((row) => row.capabilityId == 'voice.stt');
      expect(stt.availability, ModuleCapabilityAvailability.researching);
      expect(stt.statusLabel, 'In ricerca 0/2');
      expect(stt.presentCount, 0);
      expect(stt.canReuse, isFalse);
      expect(stt.research.candidateCount, 3);
      expect(stt.research.qualifiedCandidates, 2);
    });

    test('deprecated and revoked certified assets are not counted as present', () {
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[
          _asset('voice.stt.old', 'voice.stt', availability: 'deprecated'),
          _asset('voice.stt.bad', 'voice.stt', availability: 'revoked'),
        ]),
        researcherJson: _researcher(<Map<String, Object?>>[]),
      );

      final stt = rows.firstWhere((row) => row.capabilityId == 'voice.stt');
      expect(stt.presentCount, 0);
      expect(stt.certifiedDeprecated, 1);
      expect(stt.revoked, 1);
      expect(stt.availability, ModuleCapabilityAvailability.absent);
      expect(stt.canReuse, isFalse);
    });

    test('does not call a capability absent when Researcher state is unavailable', () {
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[]),
      );

      final stt = rows.firstWhere((row) => row.capabilityId == 'voice.stt');
      expect(stt.availability, ModuleCapabilityAvailability.researchUnavailable);
      expect(stt.statusLabel, 'Ricerca non disponibile 0/2');
    });

    test('shows certified capabilities that are not pre-declared as needs', () {
      final cellar = _asset('ai.model_storage.whuppi.cellar', 'ai.model_storage')
        ..['platforms'] = <String>['linux'];
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[cellar]),
        researcherJson: _researcher(<Map<String, Object?>>[]),
      );

      final storage = rows.firstWhere(
        (row) => row.capabilityId == 'ai.model_storage',
      );
      expect(storage.presentCount, 1);
      expect(storage.canReuse, isTrue);
      expect(storage.certifiedPins, <String>['ai.model_storage.whuppi.cellar@1.0.0']);
      expect(storage.targets, <String>['linux']);
      expect(storage.availability, ModuleCapabilityAvailability.complete);
    });

    test('non-certified catalog entries cannot become present', () {
      final discovered = _asset('voice.stt.intake', 'voice.stt')
        ..['status'] = 'discovered';
      final rows = ModuleCapabilityStatusProjector.project(
        needsJson: _needs(),
        catalogJson: _catalog(<Map<String, Object?>>[discovered]),
        researcherJson: _researcher(<Map<String, Object?>>[]),
      );

      final stt = rows.firstWhere((row) => row.capabilityId == 'voice.stt');
      expect(stt.presentCount, 0);
      expect(stt.canReuse, isFalse);
    });
  });
}

Map<String, Object?> _needs() => <String, Object?>{
      'schema_version': 1,
      'items': <Map<String, Object?>>[
        <String, Object?>{
          'capability_id': 'voice.stt',
          'title': 'Speech-to-text',
          'desired_candidates': 2,
          'targets': <String>['android', 'desktop'],
        },
        <String, Object?>{
          'capability_id': 'voice.tts',
          'title': 'Text-to-speech',
          'desired_candidates': 2,
          'targets': <String>['android', 'desktop'],
        },
      ],
    };

Map<String, Object?> _catalog(List<Map<String, Object?>> assets) =>
    <String, Object?>{'schema_version': 1, 'assets': assets};

Map<String, Object?> _researcher(List<Map<String, Object?>> rows) =>
    <String, Object?>{'capabilities': rows};

Map<String, Object?> _asset(
  String id,
  String capability, {
  String availability = 'active',
}) =>
    <String, Object?>{
      'id': id,
      'version': '1.0.0',
      'status': 'certified',
      'availability': availability,
      'capabilities': <String>[capability],
    };
