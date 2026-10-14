import 'dart:convert';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/inference/android/native_token_context_budget.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = 'private-session-fixture';
const _fact = 'My sample name is Neris.';
const _reread = 'rileggere questa chat, e rispondere alla domanda';

ChatMessage _message(
  String id,
  String content, {
  String role = 'user',
  String session = _session,
  List<ChatAttachment> attachments = const [],
}) => ChatMessage(
  id: id,
  sessionId: session,
  role: role,
  content: content,
  timestamp: 1,
  attachments: attachments,
);

List<ChatMessage> _history(int exchanges) => [
  for (var i = 0; i < exchanges; i++) ...[
    _message('u$i', i == 0 ? _fact : 'Topic $i.'),
    _message('a$i', 'Answer $i.', role: 'assistant'),
  ],
];

ConversationMemoryService _service({
  bool compact = false,
  MemoryWindowConfig? config,
}) => ConversationMemoryService(
  rollingContextBuilder: RollingContextBuilder(
    windowManager: MemoryWindowManager(
      tokenEstimator: const CharacterLengthEstimator(),
      configProvider: () =>
          config ??
          (compact
              ? MemoryWindowConfig.compact(isWeb: false)
              : MemoryWindowConfig.standard(isWeb: false)),
    ),
  ),
  semanticWorkspaceIndex: _NoSearchIndex(),
  embeddingService: const _NoQueryEmbedding(),
);

Map<String, dynamic> _receipt() {
  final entry = RuntimeEventLog.instance.entries.lastWhere(
    (entry) => entry.tag == 'CONTEXT_REBUILD',
  );
  return jsonDecode(publicLogProjection(entry.toString())!)
      as Map<String, dynamic>;
}

String _compose(List<ChatTurn> context, String question, {bool emit = false}) =>
    LocalPromptTemplates.compose(
      modelId: 'phi3_5_mini',
      prompt: question,
      systemPrompt: 'Be concise.',
      context: context,
      enforceLegacyContextBound: false,
      emitDiagnostics: emit,
    );

// Deterministic tokenizer double: these tests verify selection and forwarding,
// not GGUF token counts, model comprehension or physical-device capacity.
int _tokens(String prompt) => prompt.split(RegExp(r'\s+')).length;

void main() {
  setUp(() => RuntimeEventLog.instance.clear());

  const attachment = ChatAttachment(
    id: 'fixture-file',
    type: ChatAttachmentType.file,
    path: '/fixture/new-topic.txt',
    name: 'new-topic.txt',
  );

  test(
    'empty and attachment-bearing persisted actions stop retry inheritance',
    () async {
      final service = _service(compact: true);
      for (final boundary in [
        _message('empty', ''),
        _message('empty-answer', '', role: 'assistant'),
        _message('attachment-only', '', attachments: [attachment]),
        _message('attachment-retry', 'riprova', attachments: [attachment]),
      ]) {
        final context = await service.buildContext(
          usePortableRecallEnvelope: false,
          sessionId: _session,
          messages: [
            ..._history(15),
            _message('failed', _reread),
            boundary,
            _message('current', 'riprova'),
          ],
          excludedMessageId: 'current',
          userPrompt: 'riprova',
        );
        expect(_receipt()['recall_intent'], isFalse);
        expect(_receipt()['recall_requested'], isFalse);
        expect(_receipt()['recall_turns'], 0);
        expect(context.first.content, 'Topic 4.');
      }
    },
  );

  test(
    'a current retry carrying attachments is a new action, not a bare retry',
    () async {
      await _service(compact: true).buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: [
          ..._history(15),
          _message('failed', _reread),
          _message('current', 'riprova', attachments: [attachment]),
        ],
        excludedMessageId: 'current',
        userPrompt: 'riprova',
      );
      expect(_receipt()['recall_intent'], isFalse);
      expect(_receipt()['recall_turns'], 0);
    },
  );

  test(
    'portable recall uses the actual 16-turn window on Web and custom profiles',
    () async {
      for (final config in [
        MemoryWindowConfig.compact(isWeb: true),
        MemoryWindowConfig.custom(
          maxContextLines: 16,
          maxTotalSize: 3072,
          isWeb: false,
        ),
      ]) {
        for (final exchanges in [10, 15]) {
          final history = _history(exchanges);
          final context = await _service(config: config).buildContext(
            usePortableRecallEnvelope: true,
            sessionId: _session,
            messages: history,
            userPrompt: _reread,
          );
          // The last eight exchanges are already retained. Recall the two
          // complete exchanges immediately before that actual window, including
          // when all persisted turns would fit the wider 24-turn portable cap.
          expect(
            context.map((t) => t.content),
            history.skip(history.length - 20).map((m) => m.content),
          );
          expect(context, hasLength(20));
          expect(context.last.content, 'Answer ${exchanges - 1}.');
          expect(_receipt()['recent_turns'], 16);
          expect(_receipt()['recall_requested'], isTrue);
          expect(_receipt()['recall_turns'], 4);
          expect(_receipt()['trimmed_turns'], history.length - 20);
        }
      }
    },
  );

  test(
    'a reference does not shrink already retained history before token fitting',
    () async {
      final history = _history(15);
      final before = history.map((m) => (m.id, m.content)).toList();
      final service = _service();
      for (final question in [
        'What is my sample name?',
        'Come avevamo detto?',
        _reread,
      ]) {
        final current = _message('current', question);
        final context = await service.buildContext(
          usePortableRecallEnvelope: false,
          sessionId: _session,
          messages: [...history, current],
          excludedMessageId: current.id,
          userPrompt: question,
        );
        expect(context.map((t) => t.content), history.map((m) => m.content));
        expect(context, hasLength(30));
        final fit = NativeTokenContextBudget.fit(
          contextTurns: context,
          maxPromptTokens: _tokens(_compose(context, question)),
          composePrompt: (turns) => _compose(turns, question),
          countTokens: _tokens,
        );
        expect(fit.trimmedTurns, 0);
        expect(fit.fitsRequestedBudget, isTrue);
        final prompt = _compose(fit.contextTurns, question, emit: true);
        expect(prompt, contains('<|user|>\n$_fact\n<|end|>'));
        expect(
          prompt,
          endsWith('<|user|>\n$question\n<|end|>\n<|assistant|>\n'),
        );
        expect(_receipt()['trimmed_turns'], 0);
        expect(_receipt()['recall_requested'], isFalse);
      }
      expect(history.map((m) => (m.id, m.content)), before);
    },
  );

  test(
    'compact in-window fact reaches Phi prompt without durable memory',
    () async {
      final context = await _service(compact: true).buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: _history(10),
        userPrompt: 'What is my sample name?',
      );
      expect(context, hasLength(20));
      expect(_compose(context, 'What is my sample name?'), contains(_fact));
      expect(_receipt()['recall_mode'], 'recent_only');
    },
  );

  test('rereading recalls only two older complete exchanges outside the actual window', () async {
    final context = await _service(compact: true).buildContext(
      usePortableRecallEnvelope: false,
      sessionId: _session,
      messages: _history(15),
      userPrompt: _reread,
    );
    expect(context, hasLength(24));
    expect(context.take(4).map((t) => t.content), [
      'Topic 1.',
      'Answer 1.',
      'Topic 2.',
      'Answer 2.',
    ]);
    expect(context.last.content, 'Answer 14.');
    expect(_receipt(), containsPair('recall_turns', 4));
    expect(_receipt(), containsPair('trimmed_turns', 6));
    expect(_receipt(), containsPair('recall_intent', true));
  });

  test(
    'retry after failed reread inherits intent through unanswered retries only',
    () async {
      final messages = [
        ..._history(15),
        _message('failed', _reread),
        _message('failed-retry', 'riprova'),
        _message('current', 'riprova'),
      ];
      final context = await _service(compact: true).buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: messages,
        userPrompt: 'riprova',
        excludedMessageId: 'current',
      );
      expect(_receipt()['recall_intent'], isTrue);
      expect(_receipt()['recall_turns'], 4);
      expect(context, hasLength(24));
      expect(context.where((t) => t.content == _reread), hasLength(1));
      expect(context.where((t) => t.content == 'riprova'), hasLength(1));
      expect(context.last.content, 'riprova');
    },
  );

  test(
    'retry never crosses an answer, a new subject or another session',
    () async {
      final service = _service(compact: true);
      for (final boundary in [
        _message('answer', 'Completed.', role: 'assistant'),
        _message('new-question', 'Explain photosynthesis.'),
      ]) {
        await service.buildContext(
          usePortableRecallEnvelope: false,
          sessionId: _session,
          messages: [..._history(15), _message('old', _reread), boundary],
          userPrompt: 'riprova',
        );
        expect(_receipt()['recall_intent'], isFalse);
      }
      await service.buildContext(
        usePortableRecallEnvelope: false,
        sessionId: 'other',
        messages: [..._history(15), _message('failed', _reread)],
        userPrompt: 'riprova',
      );
      expect(_receipt()['history_turns'], 0);
      expect(_receipt()['recall_intent'], isFalse);
    },
  );

  test('rebuilding from saved history works after restart and empty history clears intent', () async {
    final saved = [..._history(15), _message('failed', _reread)];
    final first = await _service(compact: true).buildContext(
      usePortableRecallEnvelope: false,
      sessionId: _session,
      messages: saved,
      userPrompt: 'riprova',
    );
    final restarted = _service(compact: true);
    expect(
      await restarted.buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: saved,
        userPrompt: 'riprova',
      ),
      first,
    );
    expect(
      await restarted.buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: const [],
        userPrompt: 'riprova',
      ),
      isEmpty,
    );
    expect(_receipt()['recall_intent'], isFalse);
  });

  test('identical persisted prompts remain distinct and current ID alone is excluded', () async {
    final context = await _service().buildContext(
      usePortableRecallEnvelope: false,
      sessionId: _session,
      userPrompt: _fact,
      excludedMessageId: 'current',
      messages: [
        _message('u1', _fact),
        _message('a1', 'OK', role: 'assistant'),
        _message('u2', _fact),
        _message('a2', 'OK', role: 'assistant'),
        _message('current', _fact),
      ],
    );
    expect(context, hasLength(4));
    expect(context.where((t) => t.content == _fact), hasLength(2));
  });

  test(
    'real token selection remains authoritative when earlier fact cannot fit',
    () async {
      const question = 'What is my sample name?';
      final context = await _service().buildContext(
        usePortableRecallEnvelope: false,
        sessionId: _session,
        messages: _history(15),
        userPrompt: question,
      );
      final recent = context.sublist(context.length - 4);
      final budget = _tokens(_compose(recent, question));
      final fit = NativeTokenContextBudget.fit(
        contextTurns: context,
        maxPromptTokens: budget,
        composePrompt: (turns) => _compose(turns, question),
        countTokens: _tokens,
      );
      expect(context.first.content, _fact);
      expect(fit.contextTurns, recent);
      expect(fit.contextTurns.first.role, ChatRole.user);
      expect(fit.trimmedTurns, 26);
      expect(fit.promptTokens, lessThanOrEqualTo(budget));
      expect(
        _compose(fit.contextTurns, question, emit: true),
        isNot(contains(_fact)),
      );
      final projected = RuntimeEventLog.instance.entries
          .map((e) => publicLogProjection(e.toString()))
          .whereType<String>()
          .join('\n');
      expect(projected, contains('"context_turns":30'));
      expect(projected, contains('"turns":4'));
      expect(projected, isNot(contains(_session)));
      expect(projected, isNot(contains('Neris')));
    },
  );
}

class _NoSearchIndex extends SemanticWorkspaceIndex {
  _NoSearchIndex() : super(databaseHelper: DatabaseHelper.instance);
  @override
  Future<List<SemanticChunkMatch>> search({
    required List<double> queryVector,
    String? workspaceId,
    int topK = 6,
  }) => throw StateError('No semantic hot-path query');
}

class _NoQueryEmbedding extends WorkspaceEmbeddingService {
  const _NoQueryEmbedding();
  @override
  Future<List<double>> embedTextAsync(String text) =>
      throw StateError('No query embedding');
}
