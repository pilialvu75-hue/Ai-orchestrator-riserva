import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_acceptance_ledger.dart';

void main() {
  test('task acceptance precedes project-wide acceptance without truncation', () {
    final longTail = 'REQUIRED-END: ${'preserve the original drawing; ' * 32}LAST';
    final entries = WorkshopAcceptanceLedger.entries(
      taskCriteria: const <String>[
        'Tap changes the star color, not the background.',
        'Black background remains unchanged.',
      ],
      projectCriteria: <String>[
        'Flutter Android application stays offline-capable.',
        longTail,
      ],
    );
    expect(entries.map((e) => e.id), <String>[
      'TASK-001',
      'TASK-002',
      'PROJECT-001',
      'PROJECT-002',
    ]);
    expect(entries.last.text, longTail);
    expect(entries.last.asConstraint, contains(longTail));
    expect(entries.first.asConstraint,
        contains('Tap changes the star color, not the background.'));
    expect(entries.last.scope, WorkshopAcceptanceScope.project);
  });

  test('duplicate criteria are distinct and identifiers remain deterministic', () {
    final entries = WorkshopAcceptanceLedger.entries(
      taskCriteria: const <String>['Exact label: +', 'Exact label: +'],
      projectCriteria: const <String>['A', 'B'],
    );
    expect(entries, hasLength(4));
    expect(entries[0].id, 'TASK-001');
    expect(entries[1].id, 'TASK-002');
    expect(entries[2].id, 'PROJECT-001');
    expect(entries[3].id, 'PROJECT-002');
    expect(() => entries.add(entries.first), throwsUnsupportedError);
  });

  test('blank entries are omitted but no meaningful text is silently lost', () {
    final entries = WorkshopAcceptanceLedger.entries(
      taskCriteria: const <String>['', '  ', 'Keep literal +'],
      projectCriteria: const <String>['\n', 'No unauthorized Internet'],
    );
    expect(entries.map((e) => e.id), <String>['TASK-001', 'PROJECT-001']);
    expect(entries.map((e) => e.text),
        <String>['Keep literal +', 'No unauthorized Internet']);
  });
}
