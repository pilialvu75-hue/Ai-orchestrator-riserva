import 'dart:io';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Reads a local video and generates a short visual storyboard.
/// Does not process audio or upload the original video.
abstract interface class ChatVideoStoryboardService {
  Future<Uint8List> extractStoryboard(ChatAttachment video);
}

/// Android-only decoder. A platform channel extracts three sampled frames into
/// a JPEG contact sheet; only that JPEG may later be sent to the manually
/// selected Cloud vision provider after the user taps Send.
final class AndroidChatVideoStoryboardService
    implements ChatVideoStoryboardService {
  AndroidChatVideoStoryboardService({
    MethodChannel? channel,
    TargetPlatform? platformOverride,
  })  : _channel =
            channel ?? const MethodChannel('com.aiorchestrator/video_storyboard'),
        _platformOverride = platformOverride;

  static const int maxVideoBytes = 100 * 1024 * 1024;
  static const int maxStoryboardBytes = 8 * 1024 * 1024;

  final MethodChannel _channel;
  final TargetPlatform? _platformOverride;

  @override
  Future<Uint8List> extractStoryboard(ChatAttachment video) async {
    if (kIsWeb ||
        (_platformOverride ?? defaultTargetPlatform) !=
            TargetPlatform.android) {
      throw StateError(
        'Video: analisi dei fotogrammi disponibile per ora soltanto su Android.',
      );
    }
    if (!video.isVideo ||
        video.uploadState != ChatAttachmentUploadState.ready ||
        video.path.trim().isEmpty) {
      throw StateError('Video: seleziona prima un filmato valido.');
    }
    final extension = p.extension(video.name).toLowerCase();
    if (!const <String>{'.mp4', '.mov', '.webm'}.contains(extension)) {
      throw StateError('Video: formato non supportato. Usa MP4, MOV o WebM.');
    }
    final source = File(video.path);
    if (!await source.exists()) {
      throw StateError('Video: il filmato originale non è più disponibile.');
    }
    final length = await source.length();
    if (length <= 0 || length > maxVideoBytes) {
      throw StateError('Video: scegli un filmato non superiore a 100 MB.');
    }

    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'extractStoryboard',
        <String, Object>{'path': source.path},
      );
      if (result == null ||
          result.length < 3 ||
          result.length > maxStoryboardBytes ||
          result[0] != 0xFF ||
          result[1] != 0xD8 ||
          result[2] != 0xFF) {
        throw StateError('Video: il dispositivo non ha prodotto fotogrammi validi.');
      }
      return result;
    } on PlatformException catch (error) {
      throw StateError(
        'Video: impossibile leggere il filmato (${error.code}). '
        'Prova un MP4 breve e ripeti.',
      );
    } on MissingPluginException {
      throw StateError(
        'Video: estrazione dei fotogrammi non installata su questo dispositivo.',
      );
    }
  }
}
