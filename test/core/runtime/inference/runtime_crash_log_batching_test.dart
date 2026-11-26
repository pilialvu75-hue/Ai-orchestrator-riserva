import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _TestPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TestPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final log = RuntimeEventLog.instance;
  late Directory dir;
  late File file;
  late PathProviderPlatform original;

  setUp(() async {
    original = PathProviderPlatform.instance;
    dir = await Directory.systemTemp.createTemp('runtime-log-batch-');
    PathProviderPlatform.instance = _TestPathProvider(dir.path);
    await log.initPersistence();
    await log.clearPersistedLog();
    log.clear();
    file = File('${dir.path}/runtime_crash_log.txt');
  });

  tearDown(() async {
    await log.clearPersistedLog();
    log.clear();
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });

  test('ordinary progress does not synchronously write every chunk', () async {
    log.emit('[GENERATION_START] case=batch');
    final before = file.readAsStringSync();
    final watch = Stopwatch()..start();
    for (var i = 0; i < 24; i++) {
      log.emit('[TOKEN_STREAM] case=batch chunk=$i isFinal=false isError=false');
      log.emit('[FINAL_RESPONSE] case=batch chunk=$i isFinal=false isError=false');
    }
    watch.stop();
    print('P0B_PROGRESS_EMIT_US=${watch.elapsedMicroseconds}');
    expect(log.entries, hasLength(49));
    // No event-loop yield has occurred. A progress burst must not force
    // synchronous write+flush for each of the 48 entries.
    expect(file.readAsStringSync(), before);
    final exported = await log.readPersistedLog();
    expect(exported, contains('chunk=0 isFinal=false'));
    expect(exported, contains('chunk=23 isFinal=false'));
    expect(exported.split('\n').where((line) => line.contains('case=batch')),
        hasLength(49));
  });

  test('critical boundary persists queued progress before the marker', () {
    log.emit('[TOKEN_STREAM] case=critical chunk=1 isFinal=false isError=false');
    log.emit('[NATIVE_MODEL_LOAD_BEGIN] case=critical');
    final persisted = file.readAsStringSync();
    expect(persisted, contains('chunk=1'));
    expect(persisted, contains('[NATIVE_MODEL_LOAD_BEGIN]'));
    expect(persisted.indexOf('chunk=1'),
        lessThan(persisted.indexOf('[NATIVE_MODEL_LOAD_BEGIN]')));
  });

  test('terminal and error markers are durable before return', () {
    log.emit('[TOKEN_STREAM] case=terminal isFinal=true isError=false');
    log.emit('[FINAL_RESPONSE] case=error isFinal=false isError=true');
    expect(file.readAsStringSync(), contains('case=terminal'));
    expect(file.readAsStringSync(), contains('case=error'));
  });

  test('timer flushes progress even without a later event', () async {
    log.emit('[TOKEN_STREAM] case=timer isFinal=false isError=false');
    expect(file.readAsStringSync(), isNot(contains('case=timer')));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(file.readAsStringSync(), contains('case=timer'));
  });

  test('count bound flushes sustained progress synchronously', () {
    for (var i = 0; i < 64; i++) {
      log.emit('[TOKEN_STREAM] case=bound chunk=$i isFinal=false isError=false');
    }
    expect(file.readAsStringSync(), contains('chunk=63'));
  });

  test('byte bound flushes large progress and unknown flags stay immediate', () {
    final payload = List.filled(24000, 'x').join();
    log.emit('[TOKEN_STREAM] case=large isFinal=false isError=false $payload');
    expect(file.readAsStringSync(), contains('case=large'));
    log.emit('[TOKEN_STREAM] case=unknown');
    expect(file.readAsStringSync(), contains('case=unknown'));
  });

  test('explicit reset discards pending progress without resurrecting it', () async {
    log.emit('[TOKEN_STREAM] case=stale isFinal=false isError=false');
    await log.clearPersistedLog();
    log.emit('[GENERATION_START] case=fresh');
    final exported = await log.readPersistedLog();
    expect(exported, isNot(contains('case=stale')));
    expect(exported, contains('case=fresh'));
  });
}
