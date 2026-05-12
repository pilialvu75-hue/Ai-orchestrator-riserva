import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/planner/plan.dart';

void main() {
  group('PlanStep', () {
    test('has correct default status', () {
      final step = PlanStep(index: 0, description: 'Do something');
      expect(step.status, StepStatus.pending);
      expect(step.output, isNull);
      expect(step.error, isNull);
    });

    test('copyWith updates fields', () {
      final step = PlanStep(index: 1, description: 'Test step');
      final updated = step.copyWith(
        status: StepStatus.done,
        output: 'result',
      );
      expect(updated.status, StepStatus.done);
      expect(updated.output, 'result');
      expect(updated.index, 1);
      expect(updated.description, 'Test step');
    });

    test('toString includes index and description', () {
      final step = PlanStep(index: 2, description: 'My step');
      expect(step.toString(), contains('2'));
      expect(step.toString(), contains('My step'));
    });
  });

  group('Plan', () {
    Plan buildPlan({List<PlanStep>? steps}) {
      return Plan(
        id: 'plan-1',
        goal: 'Analyse and fix the bug',
        steps: steps ??
            [
              PlanStep(index: 0, description: 'Step A'),
              PlanStep(index: 1, description: 'Step B'),
            ],
      );
    }

    test('has created status by default', () {
      final plan = buildPlan();
      expect(plan.status, PlanStatus.created);
    });

    test('isComplete returns true when all steps are done', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')..status = StepStatus.done,
        PlanStep(index: 1, description: 'B')..status = StepStatus.done,
      ]);
      expect(plan.isComplete, isTrue);
    });

    test('isComplete returns false when any step is pending', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')..status = StepStatus.done,
        PlanStep(index: 1, description: 'B'),
      ]);
      expect(plan.isComplete, isFalse);
    });

    test('hasFailed returns true when any step failed', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')..status = StepStatus.failed,
      ]);
      expect(plan.hasFailed, isTrue);
    });

    test('hasFailed returns false when no step failed', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')..status = StepStatus.done,
      ]);
      expect(plan.hasFailed, isFalse);
    });

    test('combinedOutput concatenates non-empty outputs', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')
          ..status = StepStatus.done
          ..output = 'out-A',
        PlanStep(index: 1, description: 'B')
          ..status = StepStatus.done
          ..output = 'out-B',
      ]);
      expect(plan.combinedOutput, contains('out-A'));
      expect(plan.combinedOutput, contains('out-B'));
    });

    test('combinedOutput skips steps with no output', () {
      final plan = buildPlan(steps: [
        PlanStep(index: 0, description: 'A')..status = StepStatus.done,
        PlanStep(index: 1, description: 'B')
          ..status = StepStatus.done
          ..output = 'only-B',
      ]);
      expect(plan.combinedOutput, 'only-B');
    });

    test('toString includes id and step count', () {
      final plan = buildPlan();
      expect(plan.toString(), contains('plan-1'));
      expect(plan.toString(), contains('2'));
    });
  });
}
