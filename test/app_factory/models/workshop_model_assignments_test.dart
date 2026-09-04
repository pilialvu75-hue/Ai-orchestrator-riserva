import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';

void main() {
  const preferencesKey = 'workshop.model.assignments.v1';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('WorkshopModelAssignments persistence', () {
    test('save and load preserve a valid Workshop configuration', () async {
      final custom = WorkshopModelAssignments.withAssignment(
        WorkshopModelAssignments.defaults,
        AppAiRole.reviewer,
        'qwen2_5_3b_instruct',
      );

      await WorkshopModelAssignments.save(custom);

      final loaded = await WorkshopModelAssignments.load();

      expect(loaded, equals(custom));
    });

    test('reset restores Workshop defaults', () async {
      final custom = WorkshopModelAssignments.withAssignment(
        WorkshopModelAssignments.defaults,
        AppAiRole.engineer,
        'qwen2_5_3b_instruct',
      );

      await WorkshopModelAssignments.save(custom);
      await WorkshopModelAssignments.reset();

      final loaded = await WorkshopModelAssignments.load();

      expect(loaded, equals(WorkshopModelAssignments.defaults));
    });

    test('invalid persisted assignment falls back to defaults', () async {
      final invalid = WorkshopModelAssignments.withAssignment(
        WorkshopModelAssignments.defaults,
        AppAiRole.architect,
        'missing_workshop_model',
      );

      SharedPreferences.setMockInitialValues(
        <String, Object>{
          preferencesKey: jsonEncode(
            invalid
                .map((assignment) => assignment.toJson())
                .toList(growable: false),
          ),
        },
      );

      final loaded = await WorkshopModelAssignments.load();

      expect(loaded, equals(WorkshopModelAssignments.defaults));
    });

    test('Assistant role cannot be assigned inside Workshop', () {
      expect(
        () => WorkshopModelAssignments.withAssignment(
          WorkshopModelAssignments.defaults,
          AppAiRole.assistantOrchestrator,
          'phi3_5_mini',
        ),
        throwsArgumentError,
      );
    });
  });

  group('WorkshopFactory model assignment routing', () {
    test('uses the supplied assignment for the requested Workshop role', () {
      final custom = WorkshopModelAssignments.withAssignment(
        WorkshopModelAssignments.defaults,
        AppAiRole.architect,
        'qwen2_5_3b_instruct',
      );

      final modelId = WorkshopFactory.resolveWorkshopModelId(
        role: AppAiRole.architect,
        assignments: custom,
      );

      expect(modelId, 'qwen2_5_3b_instruct');
    });

    test('rejects the Assistant role at the Workshop factory boundary', () {
      expect(
        () => WorkshopFactory.resolveWorkshopModelId(
          role: AppAiRole.assistantOrchestrator,
          assignments: WorkshopModelAssignments.defaults,
        ),
        throwsStateError,
      );
    });
  });
}
