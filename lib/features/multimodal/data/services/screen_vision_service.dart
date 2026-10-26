import 'dart:io';
import 'dart:typed_data';

import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ScreenVisionState {
  unsupported,
  inactive,
  requesting,
  active,
}

final class ScreenVisionStatus {
  const ScreenVisionStatus({
    required this.state,
    required this.supported,
  });

  final ScreenVisionState state;
  final bool supported;

  bool get isActive => state == ScreenVisionState.active;
}

final class ScreenVisionException implements Exception {
  const ScreenVisionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ScreenVisionException($code): $message';
}

abstract interface class ScreenVisionCaptureService {
  bool get isSupported;

  Future<bool> requestProjection();

  Future<Uint8List> capturePng();

  Future<File> captureToFile();

  Future<void> stopProjection();

  Future<ScreenVisionStatus> status();
}

/// Android MediaProjection adapter for the existing multimodal attachment flow.
///
/// The Android system dialog remains the authority for projection consent.
/// Captured PNG bytes are persisted only when [captureToFile] is called, and
/// the caller remains responsible for stopping the projection session.
final class ScreenVisionService implements ScreenVisionCaptureService {
  ScreenVisionService({
    required ImageService imageService,
    MethodChannel? channel,
    TargetPlatform? platformOverride,
  })  : _imageService = imageService,
        _channel = channel ?? const MethodChannel(_channelName),
        _platformOverride = platformOverride;

  static const String _channelName = 'com.aiorchestrator/screen_vision';

  final ImageService _imageService;
  final MethodChannel _channel;
  final TargetPlatform? _platformOverride;

  @override
  bool get isSupported =>
      !kIsWeb &&
      (_platformOverride ?? defaultTargetPlatform) == TargetPlatform.android;

  @override
  Future<bool> requestProjection() async {
    _requireSupported();
    try {
      return await _channel.invokeMethod<bool>('requestProjection') ?? false;
    } on PlatformException catch (error) {
      throw ScreenVisionException(
        error.code,
        error.message ?? 'Unable to request screen projection.',
      );
    }
  }

  @override
  Future<Uint8List> capturePng() async {
    _requireSupported();
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('captureScreenshot');
      if (bytes == null || bytes.isEmpty) {
        throw const ScreenVisionException(
          'SCREEN_VISION_EMPTY_FRAME',
          'Android returned an empty screen capture.',
        );
      }
      // Never persist a partial or malformed frame as if it were a photo.
      // The Image Cloud gateway permits at most 8 MiB per image.
      const maxPngBytes = 8 * 1024 * 1024;
      if (bytes.length > maxPngBytes) {
        throw const ScreenVisionException(
          'SCREEN_VISION_FRAME_TOO_LARGE',
          'La schermata supera gli 8 MB: acquisizione annullata.',
        );
      }
      if (bytes.length < 8 ||
          bytes[0] != 0x89 ||
          bytes[1] != 0x50 ||
          bytes[2] != 0x4E ||
          bytes[3] != 0x47 ||
          bytes[4] != 0x0D ||
          bytes[5] != 0x0A ||
          bytes[6] != 0x1A ||
          bytes[7] != 0x0A) {
        throw const ScreenVisionException(
          'SCREEN_VISION_INVALID_PNG',
          'Il dispositivo non ha restituito una schermata PNG valida.',
        );
      }
      return bytes;
    } on PlatformException catch (error) {
      throw ScreenVisionException(
        error.code,
        error.message ?? 'Unable to capture the current screen.',
      );
    }
  }

  @override
  Future<File> captureToFile() async {
    final bytes = await capturePng();
    return _imageService.savePngBytes(
      bytes,
      prefix: 'screen_vision',
    );
  }

  @override
  Future<void> stopProjection() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopProjection');
    } on PlatformException catch (error) {
      throw ScreenVisionException(
        error.code,
        error.message ?? 'Unable to stop screen projection.',
      );
    }
  }

  @override
  Future<ScreenVisionStatus> status() async {
    if (!isSupported) {
      return const ScreenVisionStatus(
        state: ScreenVisionState.unsupported,
        supported: false,
      );
    }

    try {
      final raw =
          await _channel.invokeMapMethod<Object?, Object?>('getStatus') ??
              const <Object?, Object?>{};
      final active = raw['active'] == true;
      final requesting = raw['requesting'] == true;
      return ScreenVisionStatus(
        supported: raw['supported'] != false,
        state: active
            ? ScreenVisionState.active
            : requesting
                ? ScreenVisionState.requesting
                : ScreenVisionState.inactive,
      );
    } on PlatformException catch (error) {
      throw ScreenVisionException(
        error.code,
        error.message ?? 'Unable to query screen projection state.',
      );
    }
  }

  void _requireSupported() {
    if (!isSupported) {
      throw const ScreenVisionException(
        'SCREEN_VISION_UNSUPPORTED',
        'Screen Vision is available only on Android.',
      );
    }
  }
}
