import 'dart:async';
import 'dart:io';

import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum DebugLabRunStatus { idle, running, success, failed, timeout }

class DebugOverlay extends StatefulWidget {
  const DebugOverlay({
    super.key,
    required this.onSendThroughChatPipeline,
    required this.onRenderVoiceInference,
  });

  final void Function(String text, List<ChatAttachment> attachments)
      onSendThroughChatPipeline;
  final void Function({
    required String prompt,
    required String response,
  }) onRenderVoiceInference;

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  static const String _assetImagePath = 'assets/debug_lab/test_image.png';
  static const Duration _voiceTimeout = Duration(seconds: 120);
  static const Duration _chatTimeout = Duration(seconds: 10);
  static const Duration _visionTimeout = Duration(seconds: 20);

  late final LocalRuntimeProvider _runtimeProvider;
  late final LocalAiRepository _localAiRepository;

  DebugLabRunStatus _status = DebugLabRunStatus.idle;
  String _statusMessage = 'Ready';
  String _activeTest = 'None';
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _runtimeProvider = di.sl<LocalRuntimeProvider>();
    _localAiRepository = di.sl<LocalAiRepository>();
    RuntimeEventLog.instance.emit(
      '[DEBUG_LAB_FORENSIC_INIT] provider_type=${_runtimeProvider.runtimeType}'
      ' provider_hash=${_runtimeProvider.hashCode.toRadixString(16)}'
      ' note=fake_voice_to_llm_calls_this_provider_directly'
      '_bypassing_InferenceService_OrchestratorStateEngine_ChatRepository',
    );
  }

  Future<void> _runTest({
    required String testId,
    required Duration timeout,
    required Future<void> Function() action,
  }) async {
    if (_running) return;
    setState(() {
      _running = true;
      _activeTest = testId;
      _status = DebugLabRunStatus.running;
      _statusMessage = 'RUNNING';
    });
    RuntimeEventLog.instance.emit('[DEBUG_LAB_BEGIN] test=$testId');
    try {
      await action().timeout(timeout);
      RuntimeEventLog.instance.emit('[DEBUG_LAB_SUCCESS] test=$testId');
      if (!mounted) return;
      setState(() {
        _status = DebugLabRunStatus.success;
        _statusMessage = 'SUCCESS';
      });
    } on TimeoutException catch (error, stackTrace) {
      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_TIMEOUT] test=$testId error=$error stack=$stackTrace',
      );
      RuntimeEventLog.instance.emit('[DEBUG_LAB_CRASH_MARKER] test=$testId kind=timeout');
      if (!mounted) return;
      setState(() {
        _status = DebugLabRunStatus.timeout;
        _statusMessage = 'TIMEOUT';
      });
    } catch (error, stackTrace) {
      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_FAILED] test=$testId error=$error stack=$stackTrace',
      );
      RuntimeEventLog.instance.emit('[DEBUG_LAB_CRASH_MARKER] test=$testId kind=exception');
      if (!mounted) return;
      setState(() {
        _status = DebugLabRunStatus.failed;
        _statusMessage = 'FAILED';
      });
    } finally {
      RuntimeEventLog.instance.emit('[DEBUG_LAB_END] test=$testId status=${_status.name}');
      if (!mounted) return;
      setState(() {
        _running = false;
      });
    }
  }

  Future<void> _runFakeVoiceToLlm() {
    return _runTest(
      testId: 'fake_voice_to_llm',
      timeout: _voiceTimeout,
      action: () async {
        const prompt = 'ciao';
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] test=fake_voice_to_llm stage=runtime_inference_only',
        );
        // ── Forensic: direct runtime path ─────────────────────────────────────
        // This test calls _runtimeProvider.streamInference() directly.
        // It bypasses InferenceService, OrchestratorStateEngine, and
        // ChatRepository entirely.  As a consequence, the following events are
        // intentionally absent from the log:
        //   PRE_STREAM_FORWARD, PRE_STREAM_BYPASS, PRE_STREAM_INFERENCE
        // (all emitted only inside InferenceService._streamWithRetryAndGuards /
        //  _streamLocalInference).
        // FIRST_TOKEN_ATTEMPT_BEGIN is emitted inside
        // AndroidFfiRuntimeProvider._runInferenceSerially and WILL appear when
        // the serial-queue action executes.
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] test=fake_voice_to_llm'
          ' dispatch_path=DIRECT_RUNTIME_PROVIDER'
          ' provider=${_runtimeProvider.runtimeType}'
          ' provider_hash=${_runtimeProvider.hashCode.toRadixString(16)}'
          ' note=bypasses_InferenceService_OrchestratorStateEngine_ChatRepository'
          ' expected_absent=PRE_STREAM_FORWARD+PRE_STREAM_BYPASS+PRE_STREAM_INFERENCE',
        );
        // ──────────────────────────────────────────────────────────────────────
        final selectedResult = await _localAiRepository.getSelectedModel();
        final selectedModel = selectedResult.fold(
          (failure) => throw StateError('Selected model lookup failed: $failure'),
          (model) => model,
        );
        if (selectedModel == null) {
          throw StateError('No selected local model.');
        }
        final modelPath = selectedModel.localPath?.trim() ?? '';
        if (modelPath.isEmpty) {
          throw StateError('Selected model path missing.');
        }

        final sessionId =
            'debug-lab-voice-${DateTime.now().millisecondsSinceEpoch}';
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DIRECT_CALL] test=fake_voice_to_llm'
          ' target=_runtimeProvider.streamInference'
          ' sessionId=$sessionId'
          ' modelId=${selectedModel.effectiveRuntimeModelId}'
          ' modelPath=$modelPath',
        );
        final cancellationToken = CancellationToken();
        final streamedText = StringBuffer();
        String? finalChunkText;
        var chunkCount = 0;
        var firstChunkLogged = false;
        await for (final chunk in _runtimeProvider.streamInference(
          request: InferenceRequest(
            sessionId: sessionId,
            prompt: prompt,
            modelId: selectedModel.effectiveRuntimeModelId,
            modelPath: modelPath,
            maxTokens: 96,
            temperature: 0.3,
          ),
          cancellationToken: cancellationToken,
        )) {
          chunkCount++;
          if (!firstChunkLogged) {
            firstChunkLogged = true;
            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_FORENSIC_FIRST_CHUNK] test=fake_voice_to_llm'
              ' sessionId=$sessionId'
              ' isFinal=${chunk.isFinal} isError=${chunk.isError}'
              ' text_chars=${chunk.text.length}',
            );
          }
          if (chunk.runtimeNotice != null && chunk.runtimeNotice!.trim().isNotEmpty) {
            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_STAGE] test=fake_voice_to_llm notice="${chunk.runtimeNotice}"',
            );
          }
          if (chunk.isError) {
            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_FORENSIC_STREAM_ERROR] test=fake_voice_to_llm'
              ' sessionId=$sessionId error="${chunk.errorMessage}"',
            );
            throw StateError(chunk.errorMessage ?? 'Runtime inference failed.');
          }
          if (chunk.isFinal) {
            finalChunkText = chunk.text.trim();
          } else if (chunk.text.isNotEmpty) {
            streamedText.write(chunk.text);
          }
        }
        final response = (finalChunkText ?? '').trim().isNotEmpty
            ? finalChunkText!.trim()
            : streamedText.toString().trim();
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DIRECT_RESULT] test=fake_voice_to_llm'
          ' sessionId=$sessionId'
          ' total_chunks=$chunkCount'
          ' response_chars=${response.length}'
          ' streamed_chars=${streamedText.length}'
          ' final_chunk=${finalChunkText != null}',
        );
        if (response.isEmpty) {
          throw const FormatException('Runtime returned empty response.');
        }
        widget.onRenderVoiceInference(
          prompt: prompt,
          response: response,
        );
      },
    );
  }

  Future<void> _runFakeChatMessage() {
    return _runTest(
      testId: 'fake_chat_message',
      timeout: _chatTimeout,
      action: () async {
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] test=fake_chat_message stage=dispatch_send_event',
        );
        // ── Forensic: fire-and-forget chat pipeline dispatch ───────────────────
        // onSendThroughChatPipeline → ChatPage._onSend → OrchestratorStateEngine
        // .add(SendMessageEvent) → ChatRepositoryImpl.sendMessage →
        // Orchestrator.handleStream → InferenceService.stream →
        // runtimeProvider.streamInference.
        // The action returns after a 250 ms yield; the test is marked SUCCESS at
        // that point without waiting for inference to complete.  PRE_STREAM_*
        // and FIRST_TOKEN_ATTEMPT_BEGIN will appear in the log asynchronously
        // AFTER this test has already emitted DEBUG_LAB_SUCCESS.
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] test=fake_chat_message'
          ' dispatch_path=CHAT_PIPELINE_FIRE_AND_FORGET'
          ' note=dispatches_SendMessageEvent_returns_after_250ms'
          '_inference_runs_async_PRE_STREAM_events_appear_after_SUCCESS',
        );
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_chat_message'
          ' target=onSendThroughChatPipeline stage=pre_invoke',
        );
        widget.onSendThroughChatPipeline(
          'Debug Lab test: rispondi con un saluto breve e gentile.',
          const <ChatAttachment>[],
        );
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_chat_message'
          ' target=onSendThroughChatPipeline stage=post_return'
          ' note=callback_returned_synchronously_inference_continues_in_background',
        );
        // ──────────────────────────────────────────────────────────────────────
        await Future<void>.delayed(const Duration(milliseconds: 250));
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_chat_message'
          ' stage=250ms_yield_complete_action_exiting_without_inference_result',
        );
      },
    );
  }

  Future<void> _runFakeVisionRequest() {
    return _runTest(
      testId: 'fake_vision_request',
      timeout: _visionTimeout,
      action: () async {
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] test=fake_vision_request stage=load_local_asset',
        );
        final bytesData = await rootBundle.load(_assetImagePath);
        final bytes = bytesData.buffer.asUint8List(
          bytesData.offsetInBytes,
          bytesData.lengthInBytes,
        );
        final tempDirectory = await getTemporaryDirectory();
        final imageFile = File(
          '${tempDirectory.path}/debug_lab_test_image_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await imageFile.writeAsBytes(bytes, flush: true);
        final attachment = ChatAttachment(
          id: 'debug-lab-vision-${DateTime.now().millisecondsSinceEpoch}',
          type: ChatAttachmentType.image,
          path: imageFile.path,
          name: 'debug_lab_test_image.png',
          mimeType: 'image/png',
          sizeBytes: bytes.length,
          thumbnailPath: imageFile.path,
          uploadState: ChatAttachmentUploadState.ready,
        );
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] test=fake_vision_request stage=dispatch_with_attachment path=${imageFile.path}',
        );
        // ── Forensic: fire-and-forget chat pipeline dispatch (with attachment) ─
        // Same dispatch path as fake_chat_message but with an image attachment.
        // onSendThroughChatPipeline → ChatPage._onSend → OrchestratorStateEngine
        // .add(SendMessageEvent) → ChatRepositoryImpl.sendMessage →
        // Orchestrator.handleStream → InferenceService.stream.
        // The action returns after a 250 ms yield without waiting for inference.
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] test=fake_vision_request'
          ' dispatch_path=CHAT_PIPELINE_FIRE_AND_FORGET'
          ' attachment_bytes=${bytes.length}'
          ' note=dispatches_SendMessageEvent_with_image_returns_after_250ms'
          '_inference_runs_async_PRE_STREAM_events_appear_after_SUCCESS',
        );
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_vision_request'
          ' target=onSendThroughChatPipeline stage=pre_invoke'
          ' attachments=1',
        );
        widget.onSendThroughChatPipeline(
          'Debug Lab vision test: descrivi questa immagine di test.',
          <ChatAttachment>[attachment],
        );
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_vision_request'
          ' target=onSendThroughChatPipeline stage=post_return'
          ' note=callback_returned_synchronously_inference_continues_in_background',
        );
        // ──────────────────────────────────────────────────────────────────────
        await Future<void>.delayed(const Duration(milliseconds: 250));
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] test=fake_vision_request'
          ' stage=250ms_yield_complete_action_exiting_without_inference_result',
        );
      },
    );
  }

  Color _statusColor(DebugLabRunStatus status) {
    switch (status) {
      case DebugLabRunStatus.idle:
        return const Color(0xFF9CA3AF);
      case DebugLabRunStatus.running:
        return const Color(0xFFFBBF24);
      case DebugLabRunStatus.success:
        return const Color(0xFF4ADE80);
      case DebugLabRunStatus.failed:
        return const Color(0xFFF87171);
      case DebugLabRunStatus.timeout:
        return const Color(0xFFFB923C);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(_status);
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 250,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF090D14).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'DEBUG LAB',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  splashRadius: 16,
                  onPressed: _running ? null : DebugLabController.instance.close,
                  icon: const Icon(Icons.close, color: Colors.white70, size: 16),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$_statusMessage • $_activeTest',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _running ? null : _runFakeVoiceToLlm,
              child: const Text('Fake Voice → LLM'),
            ),
            const SizedBox(height: 6),
            FilledButton(
              onPressed: _running ? null : _runFakeChatMessage,
              child: const Text('Fake Chat Message'),
            ),
            const SizedBox(height: 6),
            FilledButton(
              onPressed: _running ? null : _runFakeVisionRequest,
              child: const Text('Fake Vision Request'),
            ),
          ],
        ),
      ),
    );
  }
}
