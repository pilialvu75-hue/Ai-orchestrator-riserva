import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';

/// State of one assistant execution owned by the application layer rather than
/// by a page/widget. This is intentionally provider-neutral: Cloud is the first
/// consumer, while Local runtime lifecycle remains owned by the Local track.
enum ChatExecutionStatus {
  idle,
  running,
  succeeded,
  failed,
}

final class ChatExecutionState {
  const ChatExecutionState({
    this.status = ChatExecutionStatus.idle,
    this.sessionId,
    this.partialText = '',
    this.runtimeNotice,
    this.result,
    this.error,
    this.startedAt,
    this.finishedAt,
  });

  final ChatExecutionStatus status;
  final String? sessionId;
  final String partialText;
  final String? runtimeNotice;
  final ChatMessage? result;
  final Object? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isRunning => status == ChatExecutionStatus.running;
}

/// Owns chat inference independently from ChatPage.
///
/// Navigating away from the assistant may detach every UI observer, but it must
/// not cancel or duplicate an authorized Cloud request. The repository remains
/// the single inference/persistence pipeline; this controller only owns the
/// Future and observable progress. Process-death/Android foreground execution
/// is deliberately a later ring.
final class ChatExecutionController extends ChangeNotifier {
  ChatExecutionController({required IChatRepository chatRepository})
      : _chatRepository = chatRepository;

  final IChatRepository _chatRepository;
  final Map<String, Future<ChatMessage>> _activeRuns =
      <String, Future<ChatMessage>>{};

  ChatExecutionState _state = const ChatExecutionState();
  bool _disposed = false;

  ChatExecutionState get state => _state;

  Future<ChatMessage> send({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) {
    _ensureAvailable();

    final existing = _activeRuns[sessionId];
    if (existing != null) {
      return existing;
    }

    _setState(
      ChatExecutionState(
        status: ChatExecutionStatus.running,
        sessionId: sessionId,
        startedAt: DateTime.now().toUtc(),
      ),
    );

    final run = _execute(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: systemPrompt,
      attachments: List<ChatAttachment>.unmodifiable(attachments),
    );
    _activeRuns[sessionId] = run;
    return run;
  }

  Future<ChatMessage> _execute({
    required String sessionId,
    required String userPrompt,
    required String? systemPrompt,
    required List<ChatAttachment> attachments,
  }) async {
    try {
      final result = await _chatRepository.sendMessage(
        sessionId: sessionId,
        userPrompt: userPrompt,
        systemPrompt: systemPrompt,
        attachments: attachments,
        onPartialResponse: (partialText) {
          if (_disposed) return;
          _setState(
            ChatExecutionState(
              status: ChatExecutionStatus.running,
              sessionId: sessionId,
              partialText: partialText,
              runtimeNotice: _state.runtimeNotice,
              startedAt: _state.startedAt,
            ),
          );
        },
        onRuntimeNotice: (notice) {
          if (_disposed) return;
          _setState(
            ChatExecutionState(
              status: ChatExecutionStatus.running,
              sessionId: sessionId,
              partialText: _state.partialText,
              runtimeNotice: notice,
              startedAt: _state.startedAt,
            ),
          );
        },
      );

      _setState(
        ChatExecutionState(
          status: ChatExecutionStatus.succeeded,
          sessionId: sessionId,
          partialText: _state.partialText,
          runtimeNotice: _state.runtimeNotice,
          result: result,
          startedAt: _state.startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      return result;
    } catch (error) {
      _setState(
        ChatExecutionState(
          status: ChatExecutionStatus.failed,
          sessionId: sessionId,
          partialText: _state.partialText,
          runtimeNotice: _state.runtimeNotice,
          error: error,
          startedAt: _state.startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      rethrow;
    } finally {
      _activeRuns.remove(sessionId);
    }
  }

  Future<List<ChatMessage>> getMessages(String sessionId) =>
      _chatRepository.getMessages(sessionId);

  void resetTerminalState() {
    _ensureAvailable();
    if (_state.isRunning) return;
    _setState(const ChatExecutionState());
  }

  void _setState(ChatExecutionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError('ChatExecutionController is disposed.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
