import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';

class OrchestratorStateEngine extends Bloc<ChatEvent, ChatState> {
  static const _logTag = 'ORCHESTRATOR_STATE';
  static int _instanceCreateCount = 0;
  static int _instanceDisposeCount = 0;

  OrchestratorStateEngine({
    required IChatRepository chatRepository,
  })  : _chatRepository = chatRepository,
        super(const ChatInitial()) {
    _instanceCreateCount++;

    _log(
      '[PROVIDER_CREATE] '
      'type=OrchestratorStateEngine '
      'hash=${hashCode.toRadixString(16)} '
      'create_count=$_instanceCreateCount '
      'dispose_count=$_instanceDisposeCount',
    );

    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<EditMessageEvent>(_onEditMessage);
    on<PruneHistoryEvent>(_onPruneHistory);
    on<RecoverFromStuckUiEvent>(_onRecoverFromStuckUi);
    on<DebugClearChatEvent>(_onDebugClearChat);
  }

  final IChatRepository _chatRepository;

  List<ChatMessage> _messages = [];

  _ActiveChatSend? _activeSend;
  bool get _sendInFlight => _activeSend != null;

  String? _sessionId;
  int _historyRevision = 0;
  final Map<String, Completer<void>> _clearingSessions = {};

  // Every operation that can replace the visible conversation invalidates
  // earlier reads/callbacks. Repository cancellation and deadlines stay owned
  // by the repository/runtime.
  int _beginHistoryOperation(String sessionId) {
    if (_sessionId != sessionId) {
      _sessionId = sessionId;
      _messages = <ChatMessage>[];
    }
    return ++_historyRevision;
  }

  bool _isCurrent(int revision, Emitter<ChatState> emit) =>
      revision == _historyRevision && !emit.isDone;

  Future<void> _onLoadMessages(
    LoadMessagesEvent event,
    Emitter<ChatState> emit,
  ) async {
    if (_clearingSessions.containsKey(event.sessionId)) return;
    // Use send ownership, not the currently displayed session. Returning to a
    // still-running session resumes its view and eventual reconciliation.
    final activeSend = _activeSend;
    if (activeSend != null &&
        activeSend.sessionId == event.sessionId &&
        activeSend.resume != null) {
      activeSend.resume!();
      return;
    }
    final revision = _beginHistoryOperation(event.sessionId);
    _log(
      'listener load_messages session=${event.sessionId}',
    );

    emit(const ChatLoading());

    try {
      final messages =
          await _chatRepository.getMessages(event.sessionId);
      if (!_isCurrent(revision, emit)) return;

      _messages =
          List<ChatMessage>.from(messages);

      _log(
        'message persistence load_complete '
        'session=${event.sessionId} '
        'count=${_messages.length}',
      );

      emit(
        ChatLoaded(
          messages: List.unmodifiable(_messages),
        ),
      );
    } catch (error) {
      if (!_isCurrent(revision, emit)) return;
      if (_messages.isNotEmpty) {
        emit(
          ChatLoaded(
            messages: List.unmodifiable(_messages),
            runtimeMessage: _extractErrorMessage(error),
          ),
        );
        return;
      }
      emit(
        ChatError(
          message: _extractErrorMessage(error),
        ),
      );
    }
  }

  /// Handles editing of an existing user message.
  ///
  /// The selected message and every message after it are removed
  /// from persistent storage. The remaining conversation is then
  /// loaded into [_messages] and the edited prompt is dispatched
  /// through the normal SendMessageEvent pipeline.
  Future<void> _onEditMessage(
    EditMessageEvent event,
    Emitter<ChatState> emit,
  ) async {
    if (_clearingSessions.containsKey(event.sessionId)) return;
    _log(
      '[EDIT_BEGIN] '
      'session=${event.sessionId} '
      'original_message_id=${event.originalMessageId} '
      'new_prompt_chars=${event.newUserPrompt.length}',
    );

    if (_sendInFlight) {
      _log(
        '[EDIT_BLOCKED] '
        'session=${event.sessionId} '
        'reason=send_in_flight',
      );

      emit(
        ChatLoaded(
          messages: List.unmodifiable(_messages),
          runtimeMessage:
              'Another send is already running. Please wait.',
        ),
      );

      return;
    }

    final revision = _beginHistoryOperation(event.sessionId);
    try {
      final deletedCount =
          await _chatRepository.deleteMessagesFrom(
        event.sessionId,
        event.originalMessageId,
      );
      if (!_isCurrent(revision, emit)) return;

      _log(
        '[EDIT_HISTORY_TRUNCATED] '
        'session=${event.sessionId} '
        'message_id=${event.originalMessageId} '
        'deleted=$deletedCount',
      );

      final remainingMessages =
          await _chatRepository.getMessages(
        event.sessionId,
      );
      if (!_isCurrent(revision, emit)) return;

      _messages =
          List<ChatMessage>.from(remainingMessages);

      _log(
        '[EDIT_HISTORY_RELOADED] '
        'session=${event.sessionId} '
        'remaining=${_messages.length}',
      );

      emit(
        ChatSending(
          messages: List.unmodifiable(_messages),
        ),
      );

      _log(
        '[EDIT_RESUBMIT] '
        'session=${event.sessionId} '
        'prompt_chars=${event.newUserPrompt.length}',
      );

      add(
        SendMessageEvent(
          sessionId: event.sessionId,
          userPrompt: event.newUserPrompt,
          attachments: event.attachments,
        ),
      );
    } catch (error) {
      if (!_isCurrent(revision, emit)) return;
      _log(
        '[EDIT_ERROR] '
        'session=${event.sessionId} '
        'error=$error',
      );

      emit(
        ChatLoaded(
          messages: List.unmodifiable(_messages),
          runtimeMessage: _extractErrorMessage(error),
          suggestOpeningSettings:
              _shouldSuggestOpeningSettings(error),
        ),
      );
    }
  }

  Future<void> _onSendMessage(
    SendMessageEvent event,
    Emitter<ChatState> emit,
  ) async {
    final pendingClear = _clearingSessions[event.sessionId];
    final activeSend = _activeSend;
    if (activeSend != null &&
        !(pendingClear != null &&
            activeSend.sessionId == event.sessionId &&
            activeSend.invalidatedByClear)) {
      _log(
        '[ENTRY_REENTRANCY_BLOCK] '
        'scope=OrchestratorStateEngine '
        'session=${event.sessionId} '
        'hash=${hashCode.toRadixString(16)}',
      );

      // Keep the current pending/streaming bubble visible for the active send.
      return;
    }

    final send = _ActiveChatSend(event.sessionId);
    _activeSend = send;
    var revision = _beginHistoryOperation(event.sessionId);

    try {
      await runInferenceGuarded<void>(
        scope:
            'orchestrator_state_engine.send_message',
        log: _log,
        action: () async {
          _log(
            '[VM_SEND] '
            'session=${event.sessionId} '
            'hash=${hashCode.toRadixString(16)}',
          );

          _log(
            '[ORCHESTRATOR_SEND] '
            'session=${event.sessionId} '
            'stage=state_engine_send',
          );

          _log(
            '[ORCHESTRATOR_BEGIN] '
            'session=${event.sessionId}',
          );

          _log(
            'listener send_message '
            'session=${event.sessionId} '
            'prompt_chars=${event.userPrompt.length} '
            'attachments=${event.attachments.length}',
          );

          final now =
              DateTime.now().millisecondsSinceEpoch;

          final optimisticUserMessage =
              ChatMessage(
            id: 'pending-user-$now-$revision',
            sessionId: event.sessionId,
            role: 'user',
            content: event.userPrompt,
            timestamp: now,
            attachments: List.unmodifiable(event.attachments),
          );

          // Keep one fallback for this turn in the visible history, including
          // attachment identity. Successful reads replace this snapshot with
          // persisted IDs; never append/heuristically match turns by text.
          final sendHistory = <ChatMessage>[
            if (pendingClear == null) ..._messages,
            optimisticUserMessage,
          ];
          _messages = sendHistory;

          final shouldShowAssistantPlaceholder =
              event.userPrompt.trim().isNotEmpty ||
                  event.attachments.isEmpty;

          final optimisticAssistantMessage =
              ChatMessage(
            id: 'pending-assistant-$now',
            sessionId: event.sessionId,
            role: 'assistant',
            content: '',
            timestamp: now + 1,
            provider: 'assistant',
          );

          String? runtimeNotice;
          var pendingAssistantProvider = 'assistant';
          var latestPartialContent = '';
          var acceptingCallbacks = true;

          void emitTransientSendingState() {
            if (!_isCurrent(revision, emit)) return;
            final shouldRenderAssistantBubble =
                shouldShowAssistantPlaceholder ||
                    latestPartialContent
                        .trim()
                        .isNotEmpty;

            emit(
              ChatSending(
                messages:
                    List.unmodifiable(
                  <ChatMessage>[
                    ..._messages,
                    if (shouldRenderAssistantBubble)
                      optimisticAssistantMessage
                          .copyWith(
                        content:
                            latestPartialContent,
                        provider:
                            pendingAssistantProvider,
                      ),
                  ],
                ),
                runtimeMessage:
                    runtimeNotice,
              ),
            );
          }

          send.resume = () {
            if (emit.isDone || _sessionId == event.sessionId) return;
            revision = _beginHistoryOperation(event.sessionId);
            _messages = sendHistory;
            emitTransientSendingState();
          };

          emit(
            ChatSending(
              messages:
                  List.unmodifiable(
                <ChatMessage>[
                  ..._messages,
                  if (shouldShowAssistantPlaceholder)
                    optimisticAssistantMessage,
                ],
              ),
            ),
          );

          try {
            var streamStarted = false;

            // A submitted prompt already left the composer. Keep its snapshot
            // visible and own the send gate while waiting for the clear, so it
            // is neither dropped nor persisted into a deletion in progress.
            if (pendingClear != null) await pendingClear.future;
            if (send.invalidatedByClear || emit.isDone) return;

            final sendFuture =
                _chatRepository.sendMessage(
              sessionId: event.sessionId,
              userPrompt: event.userPrompt,
              systemPrompt: event.systemPrompt,
              attachments: optimisticUserMessage.attachments,
              onPartialResponse: (partialText) {
                if (!acceptingCallbacks || !_isCurrent(revision, emit)) {
                  return;
                }

                latestPartialContent =
                    partialText;

                if (partialText.trim().isNotEmpty &&
                    !streamStarted) {
                  streamStarted = true;

                  _log(
                    '[UI_STREAM_BEGIN] '
                    'session=${event.sessionId}',
                  );
                }

                _log(
                  'streaming callbacks '
                  'session=${event.sessionId} '
                  'partial_chars=${partialText.length}',
                );

                emitTransientSendingState();
              },
              onRuntimeNotice: (notice) {
                if (!acceptingCallbacks || !_isCurrent(revision, emit)) return;
                runtimeNotice = notice;

                const cloudProviderPrefix =
                    'Cloud provider:';
                final normalizedNotice = notice.trim();
                if (normalizedNotice.startsWith(
                  cloudProviderPrefix,
                )) {
                  final cloudProvider = normalizedNotice
                      .substring(cloudProviderPrefix.length)
                      .trim();
                  if (cloudProvider.isNotEmpty) {
                    pendingAssistantProvider =
                        cloudProvider;
                  }
                }

                if (emit.isDone) {
                  return;
                }

                _log(
                  'streaming callbacks '
                  'session=${event.sessionId} '
                  'runtime_notice="$notice"',
                );

                emitTransientSendingState();
              },
            );

            // The repository/runtime owns deadlines and cancellation. A UI-only
            // Future.timeout abandons the wait without stopping inference, hides
            // late persisted replies and releases the send gate too early.
            try {
              await sendFuture;
            } finally {
              acceptingCallbacks = false;
            }
            if (!_isCurrent(revision, emit)) return;

            final messages =
                await _chatRepository.getMessages(
              event.sessionId,
            );
            if (!_isCurrent(revision, emit)) return;

            _messages =
                List<ChatMessage>.from(messages);

            _log(
              'message persistence send_complete '
              'session=${event.sessionId} '
              'count=${_messages.length}',
            );

            emit(
              ChatLoaded(
                messages:
                    List.unmodifiable(_messages),
                runtimeMessage:
                    runtimeNotice,
              ),
            );

            _log(
              '[UI_STREAM_END] '
              'session=${event.sessionId}',
            );
          } catch (error) {
            acceptingCallbacks = false;
            if (!_isCurrent(revision, emit)) return;
            _log(
              'send_message error '
              'session=${event.sessionId}: $error',
            );

            // Inference is terminal even if storage is slow or unavailable.
            // Surface its error and release this send before awaiting recovery;
            // a retry/clear/load will invalidate the recovery via its revision.
            if (identical(_activeSend, send)) _activeSend = null;
            emit(
              ChatLoaded(
                messages: List.unmodifiable(_messages),
                runtimeMessage: _extractErrorMessage(error),
                suggestOpeningSettings: _shouldSuggestOpeningSettings(error),
              ),
            );

            try {
              final messages = await _chatRepository.getMessages(
                event.sessionId,
              );
              if (!_isCurrent(revision, emit)) return;
              _messages = List<ChatMessage>.from(messages);
            } catch (_) {
              if (!_isCurrent(revision, emit)) return;
              // Retain the previous turns and this question if storage cannot
              // be read. The original inference error remains the notice.
              _log(
                'message persistence recovery_reload_failed '
                'session=${event.sessionId}',
              );
            }

            // Unpersisted partial assistant text is deliberately discarded on
            // failure, as is the empty placeholder. Only stored replies can
            // appear as completed answers in the terminal state.

            emit(
              ChatLoaded(
                messages:
                    List.unmodifiable(_messages),
                runtimeMessage:
                    _extractErrorMessage(error),
                suggestOpeningSettings:
                    _shouldSuggestOpeningSettings(
                  error,
                ),
              ),
            );
          } finally {
            _log(
              '[ORCHESTRATOR_END] '
              'session=${event.sessionId}',
            );
          }
        },
        onError: (error, stackTrace) {
          if (_isCurrent(revision, emit)) {
            emit(
              ChatLoaded(
                messages:
                    List.unmodifiable(_messages),
                runtimeMessage:
                    _extractErrorMessage(error),
                suggestOpeningSettings:
                    _shouldSuggestOpeningSettings(
                  error,
                ),
              ),
            );
          }

          _log(
            '[ASYNC_FATAL] '
            'scope=orchestrator_state_engine.send_message '
            'error=$error '
            'stack=$stackTrace',
          );
        },
      );
    } finally {
      // A clear may have released this send and a newer request may own the
      // gate. An obsolete completion must not unlock that newer request.
      if (identical(_activeSend, send)) _activeSend = null;
    }
  }

  Future<void> _onPruneHistory(
    PruneHistoryEvent event,
    Emitter<ChatState> emit,
  ) async {
    await _chatRepository.pruneHistory(
      maxAgeDays:
          AppConstants.chatHistoryMaxAgeDays,
      maxRows:
          AppConstants.chatHistoryMaxRows,
    );
  }

  Future<void> _onRecoverFromStuckUi(
    RecoverFromStuckUiEvent event,
    Emitter<ChatState> emit,
  ) async {
    if (_clearingSessions.containsKey(event.sessionId)) return;
    if (_sessionId != event.sessionId) return;
    _log(
      '[inference_loop_detected] '
      'session=${event.sessionId} '
      'source=orchestrator',
    );

    emit(
      ChatLoaded(
        messages: List.unmodifiable(_messages),
        runtimeMessage:
            event.runtimeMessage,
      ),
    );

    _log(
      '[ORCHESTRATOR_END] '
      'session=${event.sessionId} '
      'recovery=forced_ui_unlock',
    );
  }

  Future<void> _onDebugClearChat(
    DebugClearChatEvent event,
    Emitter<ChatState> emit,
  ) async {
    if (_clearingSessions.containsKey(event.sessionId)) return;
    final clearing = Completer<void>();
    _clearingSessions[event.sessionId] = clearing;
    // A background clear invalidates that session's send, not the displayed
    // conversation. Only a visible clear may replace the current view.
    final revision = _sessionId == null || _sessionId == event.sessionId
        ? _beginHistoryOperation(event.sessionId)
        : null;
    final send = _activeSend;
    if (send != null && send.sessionId == event.sessionId) {
      send.resume = null;
      send.invalidatedByClear = true;
    }
    _log(
      '[UI_DEBUG] '
      'action=clear_chat_reset_begin '
      'session=${event.sessionId}',
    );

    try {
      await _chatRepository.clearSession(
        event.sessionId,
      );
      if (send?.sessionId == event.sessionId && identical(_activeSend, send)) {
        _activeSend = null;
      }
      if (revision == null || !_isCurrent(revision, emit)) return;

      _messages = <ChatMessage>[];

      emit(
        const ChatLoaded(
          messages: <ChatMessage>[],
        ),
      );

      _log(
        '[UI_DEBUG] '
        'action=clear_chat_reset_done '
        'session=${event.sessionId}',
      );
    } catch (error) {
      if (revision == null || !_isCurrent(revision, emit)) return;
      _log(
        '[UI_DEBUG] '
        'action=clear_chat_reset_failed '
        'session=${event.sessionId} '
        'error=$error',
      );

      emit(
        ChatLoaded(
          messages:
              List.unmodifiable(_messages),
          runtimeMessage:
              _extractErrorMessage(error),
          suggestOpeningSettings:
              _shouldSuggestOpeningSettings(
            error,
          ),
        ),
      );
    } finally {
      _clearingSessions.remove(event.sessionId);
      clearing.complete();
    }
  }

  String _extractErrorMessage(Object error) {
    if (error is Failure &&
        error.message.trim().isNotEmpty) {
      return error.message;
    }

    return error.toString();
  }

  bool _shouldSuggestOpeningSettings(
    Object error,
  ) {
    final message =
        _extractErrorMessage(error).toLowerCase();

    return message.contains('settings') ||
        message.contains('api key') ||
        message.contains('not configured') ||
        message.contains(
          'switch to local ai mode',
        );
  }

  static void _log(String message) {
    debugPrint(
      '[$_logTag] $message',
    );
  }

  @override
  Future<void> close() {
    _instanceDisposeCount++;

    _log(
      '[VM_DISPOSE] '
      'type=OrchestratorStateEngine '
      'hash=${hashCode.toRadixString(16)} '
      'create_count=$_instanceCreateCount '
      'dispose_count=$_instanceDisposeCount',
    );

    _log(
      '[PROVIDER_DISPOSE] '
      'type=OrchestratorStateEngine '
      'hash=${hashCode.toRadixString(16)} '
      'create_count=$_instanceCreateCount '
      'dispose_count=$_instanceDisposeCount',
    );

    return super.close();
  }
}

class _ActiveChatSend {
  _ActiveChatSend(this.sessionId);

  final String sessionId;
  void Function()? resume;
  bool invalidatedByClear = false;
}
