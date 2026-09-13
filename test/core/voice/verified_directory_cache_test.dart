import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/verified_directory_cache.dart';

void main() {
  late Directory directory;
  late File model;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('verified-cache-');
    model = await File('${directory.path}/model').writeAsString('valid');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('unchanged reads reuse success; modified and removed files revalidate', () async {
    var checks = 0;
    final cache = VerifiedDirectoryCache((root) async {
      checks++;
      final file = File('$root/model');
      if (!await file.exists() || await file.readAsString() != 'valid') return null;
      return {'model': file.path};
    });
    expect(await cache.get(directory.path), isNotNull);
    expect(await cache.get(directory.path), isNotNull);
    expect(checks, 1);
    await model.writeAsString('broken');
    expect(await cache.get(directory.path), isNull);
    expect(checks, 2);
    await model.writeAsString('valid');
    expect(await cache.get(directory.path), isNotNull);
    await model.delete();
    expect(await cache.get(directory.path), isNull);
    expect(checks, 4);
  });

  test('clear and a new process cache require another full check', () async {
    var checks = 0;
    Future<Map<String, String>?> verify(String root) async {
      checks++;
      return {'model': model.path};
    }
    final cache = VerifiedDirectoryCache(verify);
    await cache.get(directory.path);
    cache.clear();
    await cache.get(directory.path);
    await VerifiedDirectoryCache(verify).get(directory.path);
    expect(checks, 3);
  });

  test('concurrent callers share a check and invalidation rejects its result', () async {
    final finish = Completer<Map<String, String>?>();
    final started = Completer<void>();
    var checks = 0;
    final cache = VerifiedDirectoryCache((root) {
      checks++;
      started.complete();
      return finish.future;
    });
    final first = cache.get(directory.path);
    final second = cache.get(directory.path);
    await started.future;
    cache.clear();
    finish.complete({'model': model.path});
    expect(await first, isNull);
    expect(await second, isNull);
    expect(checks, 1);
  });

  test('failure is never cached', () async {
    var checks = 0;
    final cache = VerifiedDirectoryCache((_) async { checks++; return null; });
    await cache.get(directory.path);
    await cache.get(directory.path);
    expect(checks, 2);
  });
}
