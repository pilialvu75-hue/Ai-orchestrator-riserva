import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal_decoder.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

void main() {
  group('WorkshopChangeProposalDecoder', () {
    test('decodes fenced structured file changes without applying them', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-1',
        responseText: r'''```json
{
  "summary": "Implement feature",
  "explanation": "Create and update the requested files.",
  "analysis": "Keep the change isolated.",
  "validationNotes": ["run flutter test"],
  "warnings": ["device validation pending"],
  "changes": [
    {
      "path": "lib/example.dart",
      "type": "create",
      "content": "void main() {}\n"
    },
    {
      "path": "test/example_test.dart",
      "type": "update",
      "content": "// test\n"
    },
    {
      "path": "lib/obsolete.dart",
      "type": "delete"
    }
  ]
}
```''',
      );

      expect(proposal.requestId, 'request-1');
      expect(proposal.summary, 'Implement feature');
      expect(proposal.changeCount, 3);
      expect(proposal.additions, 1);
      expect(proposal.modifications, 1);
      expect(proposal.deletions, 1);
      expect(
        proposal.changes[0].type,
        WorkspaceChangeType.addition,
      );
      expect(
        proposal.changes[0].afterContent,
        'void main() {}\n',
      );
      expect(
        proposal.affectedPaths,
        <String>[
          'lib/example.dart',
          'lib/obsolete.dart',
          'test/example_test.dart',
        ],
      );
    });

    test('rejects duplicate paths', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'request-2',
          responseText: r'''
{
  "explanation": "duplicate",
  "changes": [
    {"path":"lib/a.dart","type":"create","content":"a"},
    {"path":"lib/a.dart","type":"update","content":"b"}
  ]
}
''',
        ),
        throwsFormatException,
      );
    });

    test('rejects absolute and traversal paths', () {
      for (final path in <String>[
        '/tmp/a.dart',
        '../a.dart',
        'lib/../a.dart',
        r'C:\temp\a.dart',
      ]) {
        expect(
          () => WorkshopChangeProposalDecoder.decode(
            requestId: 'request-3',
            responseText:
                '{"explanation":"unsafe","changes":[{"path":"${path.replaceAll('\\', '\\\\')}","type":"delete"}]}',
          ),
          throwsFormatException,
          reason: path,
        );
      }
    });

    test('requires content for create and update operations', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'request-4',
          responseText: r'''
{
  "explanation": "missing content",
  "changes": [
    {"path":"lib/a.dart","type":"create"}
  ]
}
''',
        ),
        throwsFormatException,
      );
    });
  });
}
