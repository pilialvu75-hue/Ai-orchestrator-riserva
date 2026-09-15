import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/cloud_web_enriching_chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';

void main() {
  group('CloudWebEnrichingChatRepository', () {
    test('injects fresh web context before explicit Cloud inference', () async {
      final delegate = _CapturingChatRepository();
      final tool = _FakeWebSearchTool(
        result: const ToolResult(
          toolId: 'web_search',
          output: '1. Meteo Parigi\nURL: https://example.test/weather',
        ),
      );
      final repository = CloudWebEnrichingChatRepository(
        delegate: delegate,
        webSearchTool: tool,
        runtimeMode: () => AiRuntimeMode.cloud,
      );

      await repository.sendMessage(
        sessionId: 's1',
        userPrompt: 'Che tempo fa oggi a Parigi?',
        systemPrompt: 'Base assistant prompt.',
      );

      expect(tool.calls, 1);
      expect(tool.lastQuery, contains('oggi a Parigi'));
      expect(delegate.lastSystemPrompt, contains('Base assistant prompt.'));
      expect(delegate.lastSystemPrompt, contains('[WEB SEARCH RESULTS]'));
      expect(delegate.lastSystemPrompt, contains('https://example.test/weather'));
    });

    test('search failure never blocks the underlying Cloud request', () async {
      final delegate = _CapturingChatRepository();
      final tool = _FakeWebSearchTool(
        result: const ToolResult(
          toolId: 'web_search',
          output: '',
          success: false,
          error: 'network unavailable',
        ),
      );
      final repository = CloudWebEnrichingChatRepository(
        delegate: delegate,
        webSearchTool: tool,
        runtimeMode: () => AiRuntimeMode.cloud,
      );

      await repository.sendMessage(
        sessionId: 's2',
        userPrompt: 'Quali sono le ultime notizie?',
        systemPrompt: 'Base assistant prompt.',
      );

      expect(tool.calls, 1);
      expect(delegate.sendCalls, 1);
      expect(delegate.lastSystemPrompt, 'Base assistant prompt.');
    });

    test('does not pre-search ordinary Cloud conversation', () async {
      final delegate = _CapturingChatRepository();
      final tool = _FakeWebSearchTool(
        result: const ToolResult(
          toolId: 'web_search',
          output: 'unused',
        ),
      );
      final repository = CloudWebEnrichingChatRepository(
        delegate: delegate,
        webSearchTool: tool,
        runtimeMode: () => AiRuntimeMode.cloud,
      );

      await repository.sendMessage(
        sessionId: 's3',
        userPrompt: 'Spiegami la fotosintesi.',
      );

      expect(tool.calls, 0);
      expect(delegate.sendCalls, 1);
    });

    test('leaves Local and Hybrid routing untouched', () async {
      for (final mode in <AiRuntimeMode>[
        AiRuntimeMode.local,
        AiRuntimeMode.hybrid,
      ]) {
        final delegate = _CapturingChatRepository();
        final tool = _FakeWebSearchTool(
          result: const ToolResult(
            toolId: 'web_search',
            output: 'unused',
          ),
        );
        final repository = CloudWebEnrichingChatRepository(
          delegate: delegate,
          webSearchTool: tool,
          runtimeMode: () => mode,
        );

        await repository.sendMessage(
          sessionId: 's-$mode',
          userPrompt: 'Meteo oggi a Lione',
        );

        expect(tool.calls, 0);
        expect(delegate.sendCalls, 1);
      }
    });
  });
}

final class _FakeWebSearchTool implements Tool {
  _FakeWebSearchTool({required this.result});

  final ToolResult result;
  int calls = 0;
  String? lastQuery;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Fake web search';

  @override
  String get description => 'Fake';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    calls++;
    lastQuery = params['query']?.toString();
    return result;
  }
}

final class _CapturingChatRepository implements ChatRepository {
  int sendCalls = 0;
  String? lastSystemPrompt;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    return const <ChatMessage>[];
  }

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async {
    sendCalls++;
    lastSystemPrompt = systemPrompt;
    return ChatMessage(
      id: 'assistant-$sendCalls',
      sessionId: sessionId,
      role: 'assistant',
      content: 'ok',
      timestamp: sendCalls,
    );
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = 30,
    int maxRows = 500,
  }) async {
    return 0;
  }

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) async {
    return 0;
  }
}
