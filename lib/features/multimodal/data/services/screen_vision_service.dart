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

/// Android MediaProjection adapter for the existing multimodal attachment flow.
///
/// The Android system dialog remains the authority for projection consent.
/// Captured PNG bytes are persisted only when [captureToFile] is called, and
/// the caller remains responsible for stopping the projection session.
final class ScreenVisionService {
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

  bool get isSupported =>
      !kIsWeb &&
      (_platformOverride ?? defaultTargetPlatform) == TargetPlatform.android;

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
      return bytes;
    } on PlatformException catch (error) {
      throw ScreenVisionException(
        error.code,
        error.message ?? 'Unable to capture the current screen.',
      );
    }
  }

  Future<File> captureToFile() async {
    final bytes = await capturePng();
    return _imageService.savePngBytes(
      bytes,
      prefix: 'screen_vision',
    );
  }

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
