import 'package:ai_orchestrator/core/memory/assistant_confirmed_memory_conflict_resolver.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:flutter_test/flutter_test.dart';

AssistantDurableMemoryRecord _fact(
  String key,
  String text, {
  int at = 10,
  AssistantMemoryScope scope = AssistantMemoryScope.user,
  String scopeId = 'local-user',
  AssistantMemorySource source = AssistantMemorySource.userExplicit,
  AssistantMemoryStatus status = AssistantMemoryStatus.confirmed,
  String? before,
  String? after,
  String? reason,
}) => AssistantDurableMemoryRecord(
  recordKey: key,
  scope: scope,
  scopeId: scopeId,
  kind: AssistantMemoryKind.fact,
  content: text,
  source: source,
  status: status,
  updatedAt: at,
  before: before,
  after: after,
  reason: reason,
);

AssistantDurableMemoryRecord _correction({
  int at = 30,
  String before = 'Jerome è alto.',
  String after = 'Kader è alto.',
  String key = 'reviewed.entity.correction.jerome-kader',
  AssistantMemorySource source = AssistantMemorySource.userExplicit,
  AssistantMemoryStatus status = AssistantMemoryStatus.confirmed,
  AssistantMemoryScope scope = AssistantMemoryScope.user,
  String scopeId = 'local-user',
  String reason =
      AssistantConfirmedMemoryConflictResolver.reviewedCorrectionReason,
}) => _fact(
  key,
  after,
  at: at,
  before: before,
  after: after,
  reason: reason,
  source: source,
  status: status,
  scope: scope,
  scopeId: scopeId,
);

List<AssistantDurableMemoryRecord> _view(
    List<AssistantDurableMemoryRecord> records) =>
    AssistantConfirmedMemoryConflictResolver.currentView(
      conversationRecords: records
          .where((record) =>
              record.scope == AssistantMemoryScope.conversation)
          .toList(),
      userRecords: records
          .where((record) => record.scope == AssistantMemoryScope.user)
          .toList(),
    );

void main() {
  group('confirmed-only canonical correction view', () {
    test('reviewed newer correction shadows only the exact older assertion',
        () {
      final old = _fact('natural.entity.statement.jerome', 'Jerome è alto.');
      final sport = _fact('natural.entity.statement.mika',
          'Mika fa tanto sport.', at: 20);
      final correction = _correction();
      final selected = _view([old, sport, correction]);
      expect(selected.map((r) => r.recordKey),
          containsAll([sport.recordKey, correction.recordKey]));
      expect(selected.map((r) => r.recordKey), isNot(contains(old.recordKey)));
      expect(selected, hasLength(2));
      expect(AssistantConfirmedMemoryConflictResolver
          .namedReferencesForCorrection(correction), {'jerome', 'kader'});
    });

    test('an unapproved correction cannot hide a confirmed assertion', () {
      final old = _fact('old', 'Jerome è alto.');
      final pending = _correction(status: AssistantMemoryStatus.candidate);
      final selected = _view([old, pending]);
      expect(selected, hasLength(1));
      expect(selected.single.recordKey, 'old');
    });

    test('fake review marker, unverified source and unrelated predicate '
        'cannot override', () {
      final old = _fact('old', 'Jerome è alto.');
      final unreviewed = _correction(reason: 'auto_discovered');
      final notExplicit =
          _correction(key: 'reviewed.entity.correction.unverified',
              source: AssistantMemorySource.verifiedTest);
      final wrongPredicate = _correction(
        key: 'reviewed.entity.correction.wrong',
        after: 'Kader fa tanto sport.',
      );
      final result = _view([old, unreviewed, notExplicit, wrongPredicate]);
      expect(result.map((r) => r.recordKey), contains('old'));
      expect(AssistantConfirmedMemoryConflictResolver
          .isReviewedNamedCorrection(unreviewed), isFalse);
      expect(AssistantConfirmedMemoryConflictResolver
          .isReviewedNamedCorrection(notExplicit), isFalse);
      expect(AssistantConfirmedMemoryConflictResolver
          .isReviewedNamedCorrection(wrongPredicate), isFalse);
    });

    test('stale, cross-scope or identically-worded corrections cannot hide',
        () {
      final old = _fact('old', 'Jerome è alto.', at: 20);
      final stale = _correction(at: 10);
      final cross = _correction(at: 30,
          key: 'reviewed.entity.correction.other-scope',
          scope: AssistantMemoryScope.conversation, scopeId: 'other-chat');
      final noChange = _correction(
        key: 'reviewed.entity.correction.no-change',
        after: 'Jerome è alto.',
      );
      final result = _view([old, stale, cross, noChange]);
      expect(result.map((r) => r.recordKey), contains('old'));
      expect(AssistantConfirmedMemoryConflictResolver
          .isReviewedNamedCorrection(noChange), isFalse);
    });

    test('ambiguous duplicate prior statements are never silently merged',
        () {
      final oldA = _fact('old-a', 'Jerome è alto.');
      final oldB = _fact('old-b', 'Jerome è alto.');
      final selected = _view([oldA, oldB, _correction()]);
      expect(selected.map((r) => r.recordKey), containsAll(['old-a', 'old-b']));
    });

    test('identical text keys in distinct scopes are not identity evidence',
        () {
      final global = _fact('bike.current', 'La bici è blu.', at: 30);
      final local = _fact(
        'bike.current', 'La bici è rossa.',
        at: 30, scope: AssistantMemoryScope.conversation, scopeId: 'chat-1',
      );
      final selected = _view([global, local]);
      expect(selected, hasLength(2));
      expect(selected.map((r) => r.content),
          containsAll(['La bici è blu.', 'La bici è rossa.']));
    });

    test('reviewed user correction does not erase same-key conversation fact',
        () {
      final originalUser = _fact('shared.person.attribute', 'Jerome è alto.');
      final originalConversation = _fact(
        'shared.person.attribute',
        'Jerome è alto.',
        scope: AssistantMemoryScope.conversation,
        scopeId: 'other-chat',
      );
      final selected =
          _view([originalUser, originalConversation, _correction()]);
      expect(selected, hasLength(2));
      expect(
        selected.where((r) => r.recordKey == 'shared.person.attribute'),
        hasLength(1),
      );
      expect(
        selected.firstWhere(
          (r) => r.recordKey == 'shared.person.attribute',
        ).scopeId,
        'other-chat',
      );
      expect(
        selected.where((r) => r.content == 'Kader è alto.'),
        hasLength(1),
      );
    });

    test('reviewed conversation correction keeps same-key user fact',
        () {
      final originalConversation = _fact(
        'shared.person.attribute', 'Jerome è alto.',
        scope: AssistantMemoryScope.conversation,
        scopeId: 'chat-current',
      );
      final originalUser =
          _fact('shared.person.attribute', 'Jerome è alto.');
      final correction = _correction(
        scope: AssistantMemoryScope.conversation,
        scopeId: 'chat-current',
      );
      final selected =
          _view([originalUser, originalConversation, correction]);
      expect(selected, hasLength(2));
      expect(
        selected.singleWhere(
          (r) => r.recordKey == 'shared.person.attribute',
        ).scope,
        AssistantMemoryScope.user,
      );
    });

    test('newest confirmed version wins only inside a single scoped key',
        () {
      final old = _fact('bike.current', 'La bici è blu.', at: 10);
      final fresh = _fact('bike.current', 'La bici è rossa.', at: 30);
      final selected = _view([old, fresh]);
      expect(selected, hasLength(1));
      expect(selected.single.content, 'La bici è rossa.');
    });

    test('sequential reviewed corrections yield the last confirmed value',
        () {
      final old = _fact('old', 'Jerome è alto.');
      final first = _correction(at: 20);
      final second = _correction(
        at: 30, key: 'reviewed.entity.correction.kader-mika',
        before: 'Kader è alto.', after: 'Mika è alto.',
      );
      final selected = _view([old, first, second]);
      expect(selected, hasLength(1));
      expect(selected.single.content, 'Mika è alto.');
    });
  });
}
