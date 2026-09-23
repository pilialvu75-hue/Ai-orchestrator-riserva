import 'dart:typed_data';

import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/screen_vision_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/screen_vision');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ScreenVisionService service() => ScreenVisionService(
        imageService: ImageService(),
        channel: channel,
        platformOverride: TargetPlatform.android,
      );

  test('permission denial is returned without pretending capture is active',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'requestProjection') return false;
      return null;
    });

    expect(await service().requestProjection(), isFalse);
    expect(calls, <String>['requestProjection']);
  });

  test('capture before start surfaces the native lifecycle error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'captureScreenshot') {
        throw PlatformException(
          code: 'SCREEN_VISION_CAPTURE_FAILED',
          message: 'Screen Vision is not active. Request projection first.',
        );
      }
      return null;
    });

    await expectLater(
      service().capturePng(),
      throwsA(
        isA<ScreenVisionException>().having(
          (error) => error.code,
          'code',
          'SCREEN_VISION_CAPTURE_FAILED',
        ),
      ),
    );
  });

  test('returns captured PNG bytes through the multimodal boundary', () async {
    final expected = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'captureScreenshot') return expected;
      return null;
    });

    expect(await service().capturePng(), expected);
  });

  test('stop then restart performs a fresh consent request', () async {
    final calls = <String>[];
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'requestProjection') {
        starts += 1;
        return true;
      }
      return null;
    });

    final target = service();
    expect(await target.requestProjection(), isTrue);
    await target.stopProjection();
    expect(await target.requestProjection(), isTrue);

    expect(starts, 2);
    expect(
      calls,
      <String>['requestProjection', 'stopProjection', 'requestProjection'],
    );
  });

  test('non-Android target is explicitly unsupported', () async {
    final target = ScreenVisionService(
      imageService: ImageService(),
      channel: channel,
      platformOverride: TargetPlatform.windows,
    );

    expect(target.isSupported, isFalse);
    expect((await target.status()).state, ScreenVisionState.unsupported);
    await expectLater(
      target.requestProjection(),
      throwsA(isA<ScreenVisionException>()),
    );
  });
}
