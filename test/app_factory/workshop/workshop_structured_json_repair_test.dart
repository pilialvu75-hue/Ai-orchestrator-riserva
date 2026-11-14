import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal_decoder.dart';

void main() {
  group('Workshop structured JSON repair', () {
    test('repairs a literal newline in optional Engineer summary', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'physical-2949-summary-newline',
        existingPaths: const <String>{'lib/main.dart'},
        responseText: '''
{
  "summary": "The change to lib/main.dart implements
  the requested build repair",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "modification",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      expect(
        proposal.summary,
        'The change to lib/main.dart implements\n  the requested build repair',
      );
      expect(proposal.changes, hasLength(1));
      expect(proposal.changes.single.path, 'lib/main.dart');
      expect(proposal.changes.single.isModification, isTrue);
      expect(proposal.changes.single.afterContent, 'void main() {}');
    });

    test('repairs unescaped quotes in optional Engineer summary', () {
      final proposal = WorkshopChangeProposalDecoder.decode(
        requestId: 'physical-2949-summary-quotes',
        existingPaths: const <String>{'lib/main.dart'},
        responseText: '''
{
  "summary": "Update "Manga Kids" without changing the task scope",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "modification",
      "content": "void main() {}"
    }
  ]
}
''',
      );

      expect(
        proposal.summary,
        'Update "Manga Kids" without changing the task scope',
      );
      expect(proposal.changes.single.path, 'lib/main.dart');
    });

    test('keeps malformed structural fields fail closed', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'physical-2949-structural-field',
          existingPaths: const <String>{'lib/main.dart'},
          responseText: '''
{
  "summary": "Repair build",
  "changes": [
    {
      "path": "lib/main.dart",
      "type": "modification
unexpected",
      "content": "void main() {}"
    }
  ]
}
''',
        ),
        throwsFormatException,
      );
    });

    test('does not fabricate a truncated proposal without closing JSON', () {
      expect(
        () => WorkshopChangeProposalDecoder.decode(
          requestId: 'physical-2949-truncated',
          existingPaths: const <String>{'lib/main.dart'},
          responseText: '''
{
  "summary": "The change to lib/main.dart implements
''',
        ),
        throwsFormatException,
      );
    });
  });
}
