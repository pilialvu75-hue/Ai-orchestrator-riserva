import 'dart:io';

import 'package:ai_orchestrator/core/system/background_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source;
  late File destination;
  final calls = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('background-download-test');
    source = File('${directory.path}/system-download');
    destination = File('${directory.path}/model.part');
    await source.writeAsBytes([1, 2, 3, 4]);
    await destination.writeAsBytes([9]);
    calls.clear();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BackgroundDownload.channel, null);
    await directory.delete(recursive: true);
  });

  void mock(Map<String, Object> Function(MethodCall) reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BackgroundDownload.channel, (call) async {
      calls.add(call.method);
      return reply(call);
    });
  }

  Future<void> transfer({CancelToken? cancel}) => BackgroundDownload.transfer(
    url: 'https://example.org/model', title: 'Model',
    destination: destination, cancelToken: cancel,
  );

  test('reattaches completed transfer and retains source until validation', () async {
    mock((_) => {'status': 8, 'received': 4, 'total': 4, 'path': source.path});
    await transfer();
    expect(await destination.readAsBytes(), [1, 2, 3, 4]);
    expect(await source.exists(), isTrue);
    expect(calls, ['start']);
    await BackgroundDownload.release('https://example.org/model');
    expect(calls.last, 'release');
  });

  test('truncated success cannot replace a previous partial', () async {
    mock((_) => {'status': 8, 'received': 4, 'total': 12, 'path': source.path});
    await expectLater(transfer(), throwsStateError);
    expect(await destination.readAsBytes(), [9]);
    expect(calls, ['start', 'release']);
  });

  test('native failure does not publish bytes or silently restart', () async {
    mock((_) => {'status': 16, 'received': 0, 'total': 4, 'reason': 1006});
    await expectLater(transfer(), throwsStateError);
    expect(await destination.readAsBytes(), [9]);
    expect(calls, ['start']);
  });

  test('a paused system request is observed until completion, not restarted', () async {
    mock((call) => call.method == 'start'
        ? {'status': 4, 'received': 0, 'total': 4, 'reason': 2}
        : {'status': 8, 'received': 4, 'total': 4, 'path': source.path});
    await transfer();
    expect(calls, ['start', 'status']);
    expect(await destination.readAsBytes(), [1, 2, 3, 4]);
  });

  test('two observers of the same destination share one transfer', () async {
    mock((_) => {'status': 8, 'received': 4, 'total': 4, 'path': source.path});
    await Future.wait([transfer(), transfer()]);
    expect(calls, ['start']);
    expect(await destination.readAsBytes(), [1, 2, 3, 4]);
  });

  test('cancel before approval never enqueues a native download', () async {
    final token = CancelToken()..cancel('user');
    mock((_) => {});
    await expectLater(transfer(cancel: token), throwsA(isA<DioException>()));
    expect(calls, isEmpty);
  });

  test('cancel during enqueue removes the system request', () async {
    final token = CancelToken();
    mock((call) {
      if (call.method == 'start') token.cancel('user');
      return {'status': 2, 'received': 0, 'total': 4};
    });
    await expectLater(transfer(cancel: token), throwsA(isA<DioException>()));
    expect(calls, ['start', 'cancel']);
    expect(await destination.readAsBytes(), [9]);
  });
}
