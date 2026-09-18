import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/chronological_long_recall.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  required int timestamp,
}) {
  return ChatMessage(
    id: id,
    sessionId: 'session',
    role: role,
    content: content,
    timestamp: timestamp,
  );
}

void main() {
  group('ChronologicalLongRecall intent', () {
    test('recognizes explicit references to older conversation', () {
      expect(
        ChronologicalLongRecall.shouldAttempt(
          'Ti ricordi quale modello avevamo deciso di usare?',
        ),
        isTrue,
      );
      expect(
        ChronologicalLongRecall.shouldAttempt(
          'Do you remember what we decided last time?',
        ),
        isTrue,
      );
      expect(
        ChronologicalLongRecall.shouldAttempt(
          'Tu te souviens de ce qu’on avait décidé?',
        ),
        isTrue,
      );
      expect(
        ChronologicalLongRecall.shouldAttempt(
          '¿Te acuerdas de lo que habíamos decidido?',
        ),
        isTrue,
      );
    });

    test('ordinary continuation stays on the zero-recall hot path', () {
      expect(ChronologicalLongRecall.shouldAttempt('Continua.'), isFalse);
      expect(
        ChronologicalLongRecall.shouldAttempt('Spiegami meglio questo punto.'),
        isFalse,
      );
    });

    test('semantic query removes recall boilerplate but keeps subject', () {
      expect(
        ChronologicalLongRecall.semanticQuery(
          'Ti ricordi quale modello locale avevamo deciso di usare?',
        ),
        contains('quale modello locale'),
      );
    });
  });

  group('ChronologicalLongRecall merge', () {
    final messages = <ChatMessage>[
      _message(id: 'u1', role: 'user', content: 'domanda uno', timestamp: 1),
      _message(id: 'a1', role: 'assistant', content: 'risposta uno', timestamp: 2),
      _message(
        id: 'u2',
        role: 'user',
        content: 'Usiamo Phi 3.5 come modello locale',
        timestamp: 3,
      ),
      _message(
        id: 'a2',
        role: 'assistant',
        content: 'Decisione registrata: Phi 3.5.',
        timestamp: 4,
      ),
      _message(id: 'u3', role: 'user', content: 'domanda tre', timestamp: 5),
      _message(id: 'a3', role: 'assistant', content: 'risposta tre', timestamp: 6),
      _message(id: 'u4', role: 'user', content: 'domanda quattro', timestamp: 7),
      _message(id: 'a4', role: 'assistant', content: 'risposta quattro', timestamp: 8),
      _message(id: 'u5', role: 'user', content: 'domanda cinque', timestamp: 9),
      _message(id: 'a5', role: 'assistant', content: 'risposta cinque', timestamp: 10),
      _message(id: 'u6', role: 'user', content: 'domanda sei', timestamp: 11),
      _message(id: 'a6', role: 'assistant', content: 'risposta sei', timestamp: 12),
    ];

    const recent = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'domanda cinque'),
      ChatTurn(role: ChatRole.assistant, content: 'risposta cinque'),
      ChatTurn(role: ChatRole.user, content: 'domanda sei'),
      ChatTurn(role: ChatRole.assistant, content: 'risposta sei'),
    ];

    test('replaces oldest recent pair with a relevant older complete pair', () {
      final result = ChronologicalLongRecall.merge(
        messages: messages,
        excludedMessageId: null,
        recentContext: recent,
        matches: const <ChronologicalRecallMatch>[
          ChronologicalRecallMatch(messageId: 'a2', score: 0.72),
        ],
      );

      expect(result.contextTurns, const <ChatTurn>[
        ChatTurn(
          role: ChatRole.user,
          content: 'Usiamo Phi 3.5 come modello locale',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content: 'Decisione registrata: Phi 3.5.',
        ),
        ChatTurn(role: ChatRole.user, content: 'domanda sei'),
        ChatTurn(role: ChatRole.assistant, content: 'risposta sei'),
      ]);
      expect(result.recalledPairs, 1);
      expect(result.recalledTurns, 2);
      expect(result.droppedRecentTurns, 2);
      expect(result.contextTurns.length, recent.length);
    });

    test('weak semantic matches are ignored', () {
      final result = ChronologicalLongRecall.merge(
        messages: messages,
        excludedMessageId: null,
        recentContext: recent,
        matches: const <ChronologicalRecallMatch>[
          ChronologicalRecallMatch(messageId: 'u2', score: 0.12),
        ],
      );

      expect(result.contextTurns, recent);
      expect(result.recalledPairs, 0);
    });

    test('matches already inside the recent suffix are not duplicated', () {
      final result = ChronologicalLongRecall.merge(
        messages: messages,
        excludedMessageId: null,
        recentContext: recent,
        matches: const <ChronologicalRecallMatch>[
          ChronologicalRecallMatch(messageId: 'u6', score: 0.95),
        ],
      );

      expect(result.contextTurns, recent);
      expect(result.recalledPairs, 0);
    });

    test('assistant match recalls its preceding user turn as one pair', () {
      final result = ChronologicalLongRecall.merge(
        messages: messages,
        excludedMessageId: null,
        recentContext: recent,
        matches: const <ChronologicalRecallMatch>[
          ChronologicalRecallMatch(messageId: 'a1', score: 0.80),
        ],
      );

      expect(result.contextTurns.first, const ChatTurn(
        role: ChatRole.user,
        content: 'domanda uno',
      ));
      expect(result.contextTurns[1], const ChatTurn(
        role: ChatRole.assistant,
        content: 'risposta uno',
      ));
    });
  });
}
