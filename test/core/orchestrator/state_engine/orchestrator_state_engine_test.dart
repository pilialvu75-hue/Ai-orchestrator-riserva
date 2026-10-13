import 'dart:async';

import 'package:ai_orchestrator/core/error/failures.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('failed-send history reconciliation (#837)', () {
    const oldQuestion = ChatMessage(
      id: 'old-user',
      sessionId: 'session-1',
      role: 'user',
      content: 'Earlier question',
      timestamp: 1,
    );
    const oldAnswer = ChatMessage(
      id: 'old-assistant',
      sessionId: 'session-1',
      role: 'assistant',
      content: 'Earlier answer',
      timestamp: 2,
      provider: 'local',
    );
    const attachment = ChatAttachment(
      id: 'photo-1',
      type: ChatAttachmentType.image,
      path: '/images/photo.png',
      name: 'photo.png',
      mimeType: 'image/png',
      sizeBytes: 123,
      thumbnailPath: '/images/thumb.png',
    );
    const event = SendMessageEvent(
      sessionId: 'session-1',
      userPrompt: '  What is in this photo?  ',
      attachments: [attachment],
    );
    const inferenceError = ServerFailure('Inference failed. Open Settings.');

    for (final partial in ['', 'Unfinished answer']) {
      testWidgets(
        'reloads persisted user after inference error (partial: "$partial")',
        (tester) async {
          final repository = _PersistingChatRepository([
            oldQuestion,
            oldAnswer,
          ]);
          repository.onReply = (user) async {
            repository.partial?.call(partial);
            throw inferenceError;
          };
          final engine = OrchestratorStateEngine(chatRepository: repository);
          engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
          await tester.pump();
          engine.add(event);
          await tester.pump();

          final loaded = engine.state as ChatLoaded;
          expect(loaded.messages, repository.messages);
          expect(loaded.messages.take(2), [oldQuestion, oldAnswer]);
          expect(loaded.messages.last.id, 'saved-user-1');
          expect(loaded.messages.last.attachments, [attachment]);
          expect(loaded.messages.last.content, event.userPrompt.trim());
          expect(loaded.messages.any((message) => message.isPending), isFalse);
          expect(
            loaded.messages.where((message) => message.role == 'assistant'),
            [oldAnswer],
          );
          expect(loaded.runtimeMessage, inferenceError.message);
          expect(loaded.suggestOpeningSettings, isTrue);
          expect(repository.readCount, 2);
          await tester.runAsync(engine.close);
        },
      );
    }

    testWidgets(
      'retains the question, earlier turns and immutable attachments when reload fails',
      (tester) async {
        final repository = _PersistingChatRepository([oldQuestion, oldAnswer]);
        late Completer<ChatMessage> reply;
        repository.onReply = (user) {
          reply = Completer<ChatMessage>();
          return reply.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        repository.failReads = true;
        final attachments = [attachment];
        engine.add(
          SendMessageEvent(
            sessionId: event.sessionId,
            userPrompt: event.userPrompt,
            attachments: attachments,
          ),
        );
        await tester.pump();
        attachments.clear();
        repository.partial?.call('Not a completed answer');
        reply.completeError(inferenceError);
        await tester.pump();

        final loaded = engine.state as ChatLoaded;
        expect(loaded.messages.take(2), [oldQuestion, oldAnswer]);
        expect(loaded.messages.length, 3);
        expect(loaded.messages.last.content, event.userPrompt);
        expect(loaded.messages.last.attachments, [attachment]);
        expect(loaded.runtimeMessage, inferenceError.message);
        expect(loaded.suggestOpeningSettings, isTrue);
        expect(
          loaded.messages.where((message) => message.role == 'assistant'),
          [oldAnswer],
        );

        // Another failed read cannot erase the fallback either.
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect((engine.state as ChatLoaded).messages, loaded.messages);
        await tester.runAsync(engine.close);
      },
    );

    testWidgets(
      'replaces fallback IDs on retry and reload without merging identical prompts',
      (tester) async {
        final repository = _PersistingChatRepository([oldQuestion, oldAnswer]);
        repository.onReply = (_) async => throw inferenceError;
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        repository.failReads = true;
        engine.add(event);
        await tester.pump();
        expect((engine.state as ChatLoaded).messages.last.isPending, isTrue);

        repository.failReads = false;
        repository.onReply = null;
        engine.add(
          event,
        ); // A distinct turn with exactly the same text/attachment.
        await tester.pump();
        final expected = List<ChatMessage>.from(repository.messages);
        final loaded = engine.state as ChatLoaded;
        expect(loaded.messages, expected);
        expect(loaded.messages.map((message) => message.id), [
          'old-user',
          'old-assistant',
          'saved-user-1',
          'saved-user-2',
          'saved-answer-2',
        ]);
        expect(
          loaded.messages
              .where((message) => message.content == event.userPrompt.trim())
              .length,
          2,
        );
        expect(loaded.messages.any((message) => message.isPending), isFalse);
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect((engine.state as ChatLoaded).messages, expected);
        await tester.runAsync(engine.close);

        final restarted = OrchestratorStateEngine(chatRepository: repository);
        restarted.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect((restarted.state as ChatLoaded).messages, expected);
        await tester.runAsync(restarted.close);
      },
    );

    testWidgets(
      'reloads and restarts a failed turn before any subsequent send',
      (tester) async {
        final repository = _PersistingChatRepository([oldQuestion, oldAnswer]);
        repository.onReply = (_) async => throw inferenceError;
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        repository.failReads = true;
        engine.add(event);
        await tester.pump();
        repository.failReads = false;
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect((engine.state as ChatLoaded).messages, repository.messages);
        expect((engine.state as ChatLoaded).messages.last.id, 'saved-user-1');
        await tester.runAsync(engine.close);
        final restarted = OrchestratorStateEngine(chatRepository: repository);
        restarted.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect((restarted.state as ChatLoaded).messages, repository.messages);
        expect((restarted.state as ChatLoaded).messages.length, 3);
        await tester.runAsync(restarted.close);
      },
    );

    for (final clear in [true, false]) {
      for (final readFails in [true, false]) {
        testWidgets(
          'ignores obsolete recovery read after ${clear ? 'clear' : 'session switch'} (failure: $readFails)',
          (tester) async {
            const other = ChatMessage(
              id: 'other',
              sessionId: 'session-2',
              role: 'user',
              content: 'Other conversation',
              timestamp: 4,
            );
            final repository = _PersistingChatRepository([
              oldQuestion,
              oldAnswer,
              other,
            ]);
            repository.onReply = (_) async => throw inferenceError;
            final engine = OrchestratorStateEngine(chatRepository: repository);
            engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
            await tester.pump();
            late Completer<List<ChatMessage>> recovery;
            repository.onRead = (sessionId) {
              if (sessionId == 'session-2') return Future.value([other]);
              recovery = Completer<List<ChatMessage>>();
              return recovery.future;
            };
            engine.add(event);
            await tester.pump();
            final stale = repository.messages
                .where((m) => m.sessionId == 'session-1')
                .toList();
            engine.add(
              clear
                  ? const DebugClearChatEvent(sessionId: 'session-1')
                  : const LoadMessagesEvent(sessionId: 'session-2'),
            );
            await tester.pump();
            final current = engine.state;
            expect(
              (current as ChatLoaded).messages,
              clear ? <ChatMessage>[] : [other],
            );
            if (readFails) {
              recovery.completeError(StateError('old read failed'));
            } else {
              recovery.complete(stale);
            }
            await tester.pump();
            expect(engine.state, current);
            await tester.runAsync(engine.close);
          },
        );
      }
    }

    testWidgets(
      'obsolete callbacks and send completion cannot restore cleared turns or unlock a newer send',
      (tester) async {
        final repository = _PersistingChatRepository([]);
        final replies = <Completer<ChatMessage>>[];
        repository.onReply = (_) {
          final reply = Completer<ChatMessage>();
          replies.add(reply);
          return reply.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(event);
        await tester.pump();
        final oldPartial = repository.partial;
        final oldNotice = repository.notice;
        engine.add(const DebugClearChatEvent(sessionId: 'session-1'));
        await tester.pump();
        engine.add(
          const SendMessageEvent(
            sessionId: 'session-1',
            userPrompt: 'New question',
          ),
        );
        await tester.pump();
        final sending = engine.state;
        oldPartial?.call('Stale text');
        oldNotice?.call('Cloud provider: Old provider');
        replies.first.completeError(inferenceError);
        await tester.pump();
        expect(engine.state, sending);
        engine.add(event);
        await tester.pump();
        expect(repository.sendCount, 2);
        replies.last.complete(
          const ChatMessage(
            id: 'new-answer',
            sessionId: 'session-1',
            role: 'assistant',
            content: 'New answer',
            timestamp: 5,
          ),
        );
        await tester.pump();
        expect((engine.state as ChatLoaded).messages.map((m) => m.content), [
          'New question',
          'New answer',
        ]);
        await tester.runAsync(engine.close);
      },
    );

    testWidgets(
      'ignores callbacks once send failed while recovery read is still pending',
      (tester) async {
        final repository = _PersistingChatRepository([]);
        repository.onReply = (_) async => throw inferenceError;
        late Completer<List<ChatMessage>> recovery;
        repository.onRead = (_) {
          recovery = Completer<List<ChatMessage>>();
          return recovery.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(event);
        await tester.pump();
        final state = engine.state as ChatLoaded;
        expect(state.runtimeMessage, inferenceError.message);
        expect(state.suggestOpeningSettings, isTrue);
        expect(state.messages.single.content, event.userPrompt);
        repository.partial?.call('After failure');
        repository.notice?.call('After failure notice');
        await tester.pump();
        expect(engine.state, state);
        recovery.complete(List.of(repository.messages));
        await tester.pump();
        expect(
          (engine.state as ChatLoaded).runtimeMessage,
          inferenceError.message,
        );
        await tester.runAsync(engine.close);
      },
    );

    testWidgets(
      'allows retry before recovery read completes and rejects its late snapshot',
      (tester) async {
        final repository = _PersistingChatRepository([]);
        repository.onReply = (_) async => throw inferenceError;
        late Completer<List<ChatMessage>> recovery;
        repository.onRead = (_) {
          recovery = Completer<List<ChatMessage>>();
          return recovery.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(event);
        await tester.pump();
        final failed = engine.state as ChatLoaded;
        expect(failed.runtimeMessage, inferenceError.message);
        expect(failed.messages.single.content, event.userPrompt);
        final oldSnapshot = List<ChatMessage>.of(repository.messages);

        // Recovery is still outstanding; a second inference is independent.
        repository.onReply = null;
        repository.onRead = null;
        engine.add(event);
        await tester.pump();
        expect(repository.sendCount, 2);
        final retried = engine.state as ChatLoaded;
        expect(retried.runtimeMessage, isNull);
        expect(retried.messages.map((message) => message.id), [
          'saved-user-1', 'saved-user-2', 'saved-answer-2',
        ]);
        recovery.complete(oldSnapshot);
        await tester.pump();
        expect(engine.state, retried);
        await tester.runAsync(engine.close);
      },
    );

    testWidgets(
      'an older normal history load cannot replace a new successful turn',
      (tester) async {
        final repository = _PersistingChatRepository([oldQuestion, oldAnswer]);
        late Completer<List<ChatMessage>> staleRead;
        repository.onRead = (_) {
          staleRead = Completer<List<ChatMessage>>();
          return staleRead.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        repository.onRead = null;
        engine.add(event);
        await tester.pump();
        final completed = engine.state;
        staleRead.complete([oldQuestion, oldAnswer]);
        await tester.pump();
        expect(engine.state, completed);
        expect((engine.state as ChatLoaded).messages, repository.messages);
        await tester.runAsync(engine.close);
      },
    );

    testWidgets(
      'refresh and UI recovery preserve the current question without abandoning the active send',
      (tester) async {
        final repository = _PersistingChatRepository([]);
        late Completer<ChatMessage> reply;
        repository.onReply = (_) {
          reply = Completer<ChatMessage>();
          return reply.future;
        };
        final engine = OrchestratorStateEngine(chatRepository: repository);
        engine.add(event);
        await tester.pump();
        final sending = engine.state;
        engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
        await tester.pump();
        expect(engine.state, sending);
        expect(repository.readCount, 0);
        engine.add(
          const RecoverFromStuckUiEvent(
            sessionId: 'session-1',
            runtimeMessage: 'UI recovered',
          ),
        );
        await tester.pump();
        expect(
          (engine.state as ChatLoaded).messages.single.content,
          event.userPrompt,
        );
        engine.add(event);
        await tester.pump();
        expect(repository.sendCount, 1);
        reply.completeError(inferenceError);
        await tester.pump();
        expect((engine.state as ChatLoaded).messages.single.id, 'saved-user-1');
        await tester.runAsync(engine.close);
      },
    );
  });

  testWidgets(
    'does not read or send into a session while its clear is pending',
    (tester) async {
      final repository = _PersistingChatRepository([
        const ChatMessage(
          id: 'old',
          sessionId: 'session-1',
          role: 'user',
          content: 'Old',
          timestamp: 1,
        ),
      ]);
      late Completer<void> clear;
      repository.onClear = () {
        clear = Completer<void>();
        return clear.future;
      };
      final engine = OrchestratorStateEngine(chatRepository: repository);
      engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
      await tester.pump();
      engine.add(const DebugClearChatEvent(sessionId: 'session-1'));
      await tester.pump();
      engine.add(const LoadMessagesEvent(sessionId: 'session-1'));
      engine.add(
        const SendMessageEvent(sessionId: 'session-1', userPrompt: 'Too early'),
      );
      await tester.pump();
      expect(repository.readCount, 1);
      expect(repository.sendCount, 0);
      clear.complete();
      await tester.pump();
      expect((engine.state as ChatLoaded).messages, isEmpty);
      engine.add(
        const SendMessageEvent(sessionId: 'session-1', userPrompt: 'New'),
      );
      await tester.pump();
      expect((engine.state as ChatLoaded).messages, repository.messages);
      expect(repository.sendCount, 1);
      await tester.runAsync(engine.close);
    },
  );

  group('OrchestratorStateEngine', () {
    testWidgets(
      'keeps an outstanding send owned beyond the old UI deadline and displays its late reply',
      (tester) async {
        late Completer<ChatMessage> completion;
        var calls = 0;
        final answer = ChatMessage(
          id: 'late-answer',
          sessionId: 'session-1',
          role: 'assistant',
          content: 'Parigi',
          timestamp: 3,
        );
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments = const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) {
            calls++;
            // Create the future inside the same error zone as sendMessage.
            completion = Completer<ChatMessage>();
            return completion.future;
          },
          onGetMessages: (_) async => <ChatMessage>[answer],
        );
        final engine = OrchestratorStateEngine(chatRepository: repository);
        final subscription = engine.stream.listen((_) {});
        engine.add(const SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Capitale della Francia?',
        ));
        await tester.pump();
        // Cross both the former release (55s) and debug (140s) deadlines.
        await tester.pump(const Duration(minutes: 3));
        expect(engine.state, isA<ChatSending>());

        engine.add(const SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Seconda domanda',
        ));
        await tester.pump();
        expect(calls, 1);
        expect(engine.state, isA<ChatSending>());

        completion.complete(answer);
        await tester.pump();
        final loaded = engine.state as ChatLoaded;
        expect(loaded.messages.single.content, 'Parigi');
        expect(loaded.runtimeMessage, isNull);
        // Close subscriptions outside the widget test's fake async zone.
        await tester.runAsync(() async {
          await subscription.cancel();
          await engine.close().timeout(const Duration(seconds: 5));
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    testWidgets(
      'reports a repository timeout, preserves its question and allows a subsequent request',
      (tester) async {
        late Completer<ChatMessage> completion;
        var calls = 0;
        final persisted = <ChatMessage>[];
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments = const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) {
            calls++;
                persisted.add(
                  ChatMessage(
                    id: 'timeout-user-$calls',
                    sessionId: sessionId,
                    role: 'user',
                    content: userPrompt,
                    timestamp: calls,
                  ),
                );
                // Create the future inside the same error zone as sendMessage.
            completion = Completer<ChatMessage>();
            return completion.future.then((answer) {
                  persisted.add(answer);
                  return answer;
                });
          },
          onGetMessages: (_) async => List.of(persisted),
        );
        final engine = OrchestratorStateEngine(chatRepository: repository);
        final subscription = engine.stream.listen((_) {});
        const event = SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Ciao',
        );
        engine.add(event);
        await tester.pump();
        completion.completeError(TimeoutException('runtime deadline'));
        await tester.pump();
        expect(engine.state, isA<ChatLoaded>());
        expect(
          (engine.state as ChatLoaded).runtimeMessage,
          contains('runtime deadline'),
        );
        expect(
          (engine.state as ChatLoaded).messages.single.id,
          'timeout-user-1',
        );
        expect((engine.state as ChatLoaded).messages.single.content, 'Ciao');
        engine.add(event);
        await tester.pump();
        expect(calls, 2);
        completion.complete(ChatMessage(
          id: 'second-answer',
          sessionId: 'session-1',
          role: 'assistant',
          content: 'Ciao',
          timestamp: 4,
        ));
        await tester.pump();
        expect(engine.state, isA<ChatLoaded>());
        expect(
          (engine.state as ChatLoaded).messages.map((message) => message.id),
          ['timeout-user-1', 'timeout-user-2', 'second-answer'],
        );
        // Close subscriptions outside the widget test's fake async zone.
        await tester.runAsync(() async {
          await subscription.cancel();
          await engine.close().timeout(const Duration(seconds: 5));
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'keeps partial assistant content and Cloud provider across generic runtime notices',
      () async {
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments =
                const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) async {
            onPartialResponse?.call('partial vision response');
            onRuntimeNotice?.call('Cloud provider: Gemini');
            onRuntimeNotice?.call('runtime still processing');
            return ChatMessage(
              id: 'assistant-final',
              sessionId: sessionId,
              role: 'assistant',
              content: 'final response',
              timestamp: 3,
              provider: 'gemini',
            );
          },
          onGetMessages: (sessionId) async {
            return <ChatMessage>[
              ChatMessage(
                id: 'user-final',
                sessionId: sessionId,
                role: 'user',
                content: '',
                timestamp: 1,
              ),
              ChatMessage(
                id: 'assistant-final',
                sessionId: sessionId,
                role: 'assistant',
                content: 'final response',
                timestamp: 3,
                provider: 'gemini',
              ),
            ];
          },
        );

        final engine =
            OrchestratorStateEngine(chatRepository: repository);
        final emittedStates = <ChatState>[];
        final subscription =
            engine.stream.listen(emittedStates.add);

        engine.add(
          const SendMessageEvent(
            sessionId: 'session-1',
            userPrompt: '',
            attachments: <ChatAttachment>[
              ChatAttachment(
                id: 'a1',
                type: ChatAttachmentType.image,
                path: '/tmp/test-image.png',
                name: 'test-image.png',
              ),
            ],
          ),
        );

        await Future<void>.delayed(
          const Duration(milliseconds: 50),
        );

        final sendingStates =
            emittedStates.whereType<ChatSending>().toList();

        final cloudProviderState =
            sendingStates.lastWhere(
          (state) =>
              state.runtimeMessage == 'Cloud provider: Gemini',
        );
        final cloudProviderAssistant =
            cloudProviderState.messages.singleWhere(
          (message) => message.role == 'assistant',
        );
        expect(
          cloudProviderAssistant.content,
          'partial vision response',
        );
        expect(cloudProviderAssistant.provider, 'Gemini');

        final genericNoticeState =
            sendingStates.lastWhere(
          (state) =>
              state.runtimeMessage == 'runtime still processing',
        );
        final genericNoticeAssistant =
            genericNoticeState.messages.singleWhere(
          (message) => message.role == 'assistant',
        );
        expect(
          genericNoticeAssistant.content,
          'partial vision response',
        );
        expect(genericNoticeAssistant.provider, 'Gemini');

        await subscription.cancel();
        await engine.close();
      },
    );
  });
}

// Models the repository's relevant contract: persist the user before invoking
// inference, persist only completed replies, and return authoritative snapshots.
class _PersistingChatRepository implements IChatRepository {
  _PersistingChatRepository(List<ChatMessage> initial)
    : messages = List.of(initial);

  final List<ChatMessage> messages;
  Future<ChatMessage> Function(ChatMessage user)? onReply;
  Future<List<ChatMessage>> Function(String sessionId)? onRead;
  Future<void> Function()? onClear;
  void Function(String)? partial;
  void Function(String)? notice;
  bool failReads = false;
  int readCount = 0;
  int sendCount = 0;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    readCount++;
    if (failReads) throw StateError('History is unavailable');
    if (onRead != null) return onRead!(sessionId);
    return messages.where((m) => m.sessionId == sessionId).toList();
  }

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const [],
    void Function(String)? onPartialResponse,
    void Function(String)? onRuntimeNotice,
  }) async {
    final turn = ++sendCount;
    partial = onPartialResponse;
    notice = onRuntimeNotice;
    final user = ChatMessage(
      id: 'saved-user-$turn',
      sessionId: sessionId,
      role: 'user',
      content: userPrompt.trim(),
      timestamp: 10 + turn * 2,
      attachments: List.unmodifiable(attachments),
    );
    messages.add(user);
    final answer = onReply == null
        ? ChatMessage(
            id: 'saved-answer-$turn',
            sessionId: sessionId,
            role: 'assistant',
            content: 'Completed answer $turn',
            timestamp: 11 + turn * 2,
          )
        : await onReply!(user);
    messages.add(answer);
    return answer;
  }

  @override
  Future<void> clearSession(String sessionId) async {
    if (onClear != null) await onClear!();
    messages.removeWhere((m) => m.sessionId == sessionId);
  }

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;

  @override
  Future<int> pruneHistory({int maxAgeDays = 0, int maxRows = 0}) async => 0;
}

class _FakeChatRepository implements IChatRepository {
  _FakeChatRepository({
    required this.onSendMessage,
    required this.onGetMessages,
  });

  final Future<ChatMessage> Function({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments,
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) onSendMessage;

  final Future<List<ChatMessage>> Function(String sessionId)
      onGetMessages;

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) async =>
      0;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) =>
      onGetMessages(sessionId);

  @override
  Future<int> pruneHistory({
    int maxAgeDays = 0,
    int maxRows = 0,
  }) async =>
      0;

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments =
        const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) {
    return onSendMessage(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: systemPrompt,
      attachments: attachments,
      onPartialResponse: onPartialResponse,
      onRuntimeNotice: onRuntimeNotice,
    );
  }
}
