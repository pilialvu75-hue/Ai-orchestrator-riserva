import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';

void main() {
  group('MemoryWindowManager', () {
    test('returns an unmodifiable snapshot without system turns', () {
      final source = <ChatTurn>[
        const ChatTurn(role: ChatRole.system, content: 'system'),
        const ChatTurn(role: ChatRole.user, content: 'alpha'),
        const ChatTurn(role: ChatRole.assistant, content: 'beta'),
      ];

      final manager = MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.standard(isWeb: false),
      );

      final result = manager.trimToWindow(
        systemPrompt: 'stay focused',
        userPrompt: 'question',
        contextTurns: source,
      );

      source[1] = const ChatTurn(role: ChatRole.user, content: 'changed');

      expect(result.contextTurns, const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'alpha'),
        ChatTurn(role: ChatRole.assistant, content: 'beta'),
      ]);
      expect(
        result.contextTurns.every((turn) => turn.role != ChatRole.system),
        isTrue,
      );
      expect(
        () => result.contextTurns.add(
          const ChatTurn(role: ChatRole.user, content: 'delta'),
        ),
        throwsUnsupportedError,
      );
    });

    test('trims the oldest turns first while preserving order', () {
      final manager = MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 2,
          maxTotalSize: 1000,
          isWeb: false,
        ),
      );

      final result = manager.trimToWindow(
        systemPrompt: null,
        userPrompt: 'prompt',
        contextTurns: const <ChatTurn>[
          ChatTurn(role: ChatRole.system, content: 'system'),
          ChatTurn(role: ChatRole.user, content: 'first'),
          ChatTurn(role: ChatRole.assistant, content: 'second'),
          ChatTurn(role: ChatRole.user, content: 'third'),
        ],
      );

      expect(result.contextTurns, const <ChatTurn>[
        ChatTurn(role: ChatRole.assistant, content: 'second'),
        ChatTurn(role: ChatRole.user, content: 'third'),
      ]);
      expect(result.trimmedLines, 2);
      expect(result.overflowDetected, isFalse);
    });

    test('reduces overflow without reordering remaining turns', () {
      final manager = MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 10,
          maxTotalSize: 512,
          isWeb: false,
        ),
      );

      final longContent = 'a' * 270;

      final result = manager.trimToWindow(
        systemPrompt: 'system',
        userPrompt: 'prompt',
        contextTurns: <ChatTurn>[
          ChatTurn(role: ChatRole.user, content: longContent),
          ChatTurn(role: ChatRole.assistant, content: longContent),
          ChatTurn(role: ChatRole.user, content: longContent),
        ],
      );

      expect(result.overflowDetected, isTrue);
      expect(
        result.contextTurns.every((turn) => turn.role != ChatRole.system),
        isTrue,
      );
      expect(result.contextTurns.last.content, longContent);
    });

    test('trims oldest turns while respecting maxContextLines', () {
      final manager = MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 16,
          maxTotalSize: 1000,
          isWeb: false,
        ),
      );

      final result = manager.trimToWindow(
        systemPrompt: null,
        userPrompt: 'prompt',
        contextTurns: List<ChatTurn>.generate(18, (index) {
          if (index == 0) {
            return const ChatTurn(role: ChatRole.system, content: 'system');
          }
          return ChatTurn(
            role: index.isEven ? ChatRole.assistant : ChatRole.user,
            content: 'turn-$index',
          );
        }),
      );

      expect(
        result.contextTurns,
        List<ChatTurn>.generate(16, (index) {
          final turnNumber = index + 2;
          return ChatTurn(
            role: turnNumber.isEven ? ChatRole.assistant : ChatRole.user,
            content: 'turn-$turnNumber',
          );
        }),
      );
      expect(result.trimmedLines, 2);
    });

    test('does not floor the available context budget before trimming', () {
      final manager = MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 16,
          maxTotalSize: 512,
          minContextSize: 64,
          isWeb: false,
        ),
      );
      final userTurn = 'a' * 200;
      final assistantTurn = 'b' * 200;
      final latestTurn = 'c' * 200;

      final result = manager.trimToWindow(
        systemPrompt: 'system-1234',
        userPrompt: 'prompt-5678',
        contextTurns: <ChatTurn>[
          ChatTurn(role: ChatRole.user, content: userTurn),
          ChatTurn(role: ChatRole.assistant, content: assistantTurn),
          ChatTurn(role: ChatRole.user, content: latestTurn),
        ],
      );

      expect(result.contextTurns, <ChatTurn>[
        ChatTurn(role: ChatRole.assistant, content: assistantTurn),
        ChatTurn(role: ChatRole.user, content: latestTurn),
      ]);
      expect(result.trimmedLines, 1);
      expect(result.overflowDetected, isTrue);
    });
  });
}
