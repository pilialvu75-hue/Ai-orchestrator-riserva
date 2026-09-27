import 'dart:convert';

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

    test('recovers one balanced JSON object surrounded by model prose', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-prose',
        responseText: r'''
Ecco la proposta strutturata:
{
  "summary": "Counter app",
  "explanation": "Create the requested counter.",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "create",
      "content": "void main() { print(\"{ok}\"); }"
    }
  ],
  "validationNotes": [],
  "warnings": []
}
Fine.
''',
      );

      expect(proposal.requestId, 'request-prose');
      expect(proposal.summary, 'Counter app');
      expect(proposal.changeCount, 1);
      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(
        proposal.changes.single.afterContent,
        'void main() { print("{ok}"); }',
      );
    });

    test('repairs raw Dart content without weakening proposal schema', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-loose-content',
        responseText: '''
{
  "summary": "Walking app",
  "explanation": "Create the requested screen.",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition",
      "content": "
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(home: Text("Walk")));
}
"
    }
  ],
  "validationNotes": [],
  "warnings": []
}
''',
      );

      expect(proposal.changeCount, 1);
      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(
        proposal.changes.single.afterContent,
        contains("import 'package:flutter/material.dart';"),
      );
      expect(
        proposal.changes.single.afterContent,
        contains('Text("Walk")'),
      );
    });

    test('strips only an outer markdown fence from file content', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-fenced-file',
        responseText: jsonEncode(<String, Object?>{
          'explanation': 'Create main',
          'changes': <Object?>[
            <String, Object?>{
              'path': 'lib/main.dart',
              'type': 'addition',
              'content':
                  '\x60\x60\x60dart\nimport \'package:flutter/material.dart\';\n\nvoid main() {}\n\x60\x60\x60',
            },
          ],
        }),
      );

      expect(
        proposal.changes.single.afterContent,
        "import 'package:flutter/material.dart';\n\nvoid main() {}",
      );
    });

    test('preserves internal markdown fences that do not wrap whole file', () {
      final content =
          "const text = 'prefix\\n\x60\x60\x60dart\\ncode\\n\x60\x60\x60\\nsuffix';";
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-internal-fence',
        responseText: jsonEncode(<String, Object?>{
          'explanation': 'Create text fixture',
          'changes': <Object?>[
            <String, Object?>{
              'path': 'lib/text.dart',
              'type': 'addition',
              'content': content,
            },
          ],
        }),
      );

      expect(proposal.changes.single.afterContent, content);
    });

    test('resolves add-or-modify from authoritative workspace paths', () {
      final added = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-ambiguous-add',
        responseText: r'''
{
  "explanation": "Create main",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition|modification",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      final modified = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-ambiguous-modify',
        responseText: r'''
{
  "explanation": "Update main",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition|modification",
      "content": "void main() { print('walk'); }"
    }
  ]
}
''',
        existingPaths: const <String>{'lib/main.dart'},
      );

      expect(added.changes.single.isAddition, isTrue);
      expect(modified.changes.single.isModification, isTrue);
    });

    test('does not normalize unsafe composite change types', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'request-ambiguous-delete',
          responseText: r'''
{
  "explanation": "Ambiguous delete",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition|deletion",
      "content": "void main() {}"
    }
  ]
}
''',
          existingPaths: const <String>{'lib/main.dart'},
        ),
        throwsFormatException,
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

    test('normalizes a benign leading dot path only', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-leading-dot',
        responseText: r'''
{
  "explanation": "Create main",
  "changes": [
    {
      "path": "./lib/main.dart",
      "type": "addition",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(proposal.changes.single.isAddition, isTrue);
    });

    test('rejects absolute and traversal paths', () {
      for (final path in <String>[
        '/tmp/a.dart',
        '../a.dart',
        'lib/../a.dart',
        'lib/./a.dart',
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


    test('uses summary when explanation is omitted', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-summary-fallback',
        responseText: r'''
{
  "summary": "Counter MVP",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      expect(proposal.explanation, 'Counter MVP');
      expect(proposal.changes.single.path, 'lib/main.dart');
    });

    test('uses analysis when explanation and summary are omitted', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'request-analysis-fallback',
        responseText: r'''
{
  "analysis": "Implement the bounded counter task.",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      expect(proposal.explanation, 'Implement the bounded counter task.');
    });

    test('still rejects a proposal with no explanatory metadata', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'request-no-explanation',
          responseText: r'''
{
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition",
      "content": "void main() {}"
    }
  ]
}
''',
        ),
        throwsFormatException,
      );
    });

    test('still rejects non-text explanation metadata', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'request-non-text-explanation',
          responseText: r'''
{
  "summary": "Counter MVP",
  "explanation": 42,
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "addition",
      "content": "void main() {}"
    }
  ]
}
''',
        ),
        throwsFormatException,
      );
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
