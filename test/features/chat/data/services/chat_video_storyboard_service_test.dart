import 'dart:io';
import 'dart:typed_data';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_video_storyboard_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/video_storyboard');

  late Directory directory;
  late ChatAttachment video;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video-storyboard-test-');
    final source = File('${directory.path}/example.mp4');
    await source.writeAsBytes(const <int>[1, 2, 3, 4]);
    video = ChatAttachment(
      id: 'video1',
      type: ChatAttachmentType.video,
      path: source.path,
      name: 'example.mp4',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  AndroidChatVideoStoryboardService service({
    TargetPlatform platform = TargetPlatform.android,
  }) =>
      AndroidChatVideoStoryboardService(
        channel: channel,
        platformOverride: platform,
      );

  test('extracts actual JPEG storyboard bytes, leaving the video unchanged',
      () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      expect(call.arguments, <String, Object>{'path': video.path});
      return Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
    });
    final jpeg = await service().extractStoryboard(video);
    expect(jpeg, <int>[0xFF, 0xD8, 0xFF, 0xD9]);
    expect(methods, <String>['extractStoryboard']);
    expect(await File(video.path).readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('rejects malformed storyboard without uploading or saving', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async =>
            Uint8List.fromList(const <int>[1, 2, 3, 4]));
    await expectLater(
      service().extractStoryboard(video),
      throwsStateError,
    );
  });

  test('native decoder errors do not expose file paths', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'VIDEO_FRAME_DECODE_FAILED',
        message: 'private path ${video.path}',
      );
    });

    try {
      await service().extractStoryboard(video);
      fail('Expected native error');
    } catch (error) {
      expect(error.toString(), contains('VIDEO_FRAME_DECODE_FAILED'));
      expect(error.toString(), isNot(contains(video.path)));
    }
  });

  test('unsupported platforms do not open the native video', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF]);
    });
    await expectLater(
      service(platform: TargetPlatform.windows).extractStoryboard(video),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('rejects unsupported containers without calling Android', () async {
    final wrong = video.copyWith(name: 'example.mkv');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF]);
    });
    await expectLater(service().extractStoryboard(wrong), throwsStateError);
    expect(calls, 0);
  });

  test('rejects videos larger than 100 MB without invoking native code',
      () async {
    final file = File(video.path);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.truncate(AndroidChatVideoStoryboardService.maxVideoBytes + 1);
    } finally {
      await handle.close();
    }
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF]);
    });
    await expectLater(service().extractStoryboard(video), throwsStateError);
    expect(calls, 0);
  });
}
