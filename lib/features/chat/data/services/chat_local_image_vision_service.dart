import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cantiere_local_image_vision/cantiere_local_image_vision.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_image_vision_service.dart';

/// The first offline image capability: device-side category labels, NOT a
/// general-purpose VLM. Never claim colors, counts, OCR, or details not proven
/// by the labels. Future mtmd/vision GGUF support will use a separate backend.
final class AndroidChatLocalImageVisionService implements ChatImageVisionService {
  AndroidChatLocalImageVisionService({
    MethodChannel? channel,
    bool? supportedPlatform,
  })  : _channel =
            channel ?? const MethodChannel('com.aiorchestrator/local_image_vision'),
        _supportedPlatform = supportedPlatform ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const int maxImageBytes = 8 * 1024 * 1024;
  static const Duration requestTimeout = Duration(seconds: 20);
  final MethodChannel _channel;
  final bool _supportedPlatform;

  @override
  Future<ChatImageVisionResult> analyze({
    required String providerId,
    required ChatAttachment image,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
  }) async {
    if (providerId != 'local') {
      throw StateError('Il riconoscimento visivo locale non usa provider Cloud.');
    }
    if (!_supportedPlatform) {
      throw UnsupportedError(
        'Il riconoscimento Image offline non è ancora supportato su questa '
        'piattaforma. Non è stata inviata alcuna immagine al Cloud.',
      );
    }
    if (!image.isImage ||
        image.uploadState != ChatAttachmentUploadState.ready ||
        image.path.trim().isEmpty) {
      throw StateError('Immagine non disponibile o ancora in preparazione.');
    }
    final file = File(image.path);
    if (!await file.exists()) {
      throw StateError('Immagine originale non trovata: selezionala di nuovo.');
    }
    final fileSize = await file.length();
    if (fileSize <= 0 || fileSize > maxImageBytes) {
      throw StateError('Image LOCAL accetta immagini fino a 8 MB.');
    }
    // Reuse the tested first-party Library plugin. Its Android FlutterPlugin
    // owns the ONLY MethodChannel registration; never forward pixels, user
    // question, context or credentials to a Cloud provider.
    try {
      final processed = await CantiereLocalImageVision(
        channel: _channel,
        supportedPlatform: _supportedPlatform,
      ).labelFile(file.path);
      return ChatImageVisionResult(
        providerId: LocalImageLabelResult.providerId,
        text: processed.text,
      );
    } on TimeoutException {
      throw StateError(
        'Image LOCAL: riconoscimento troppo lento. Riprova con una foto '
        'più piccola; nessuna immagine è stata inviata al Cloud.',
      );
    }
  }
}