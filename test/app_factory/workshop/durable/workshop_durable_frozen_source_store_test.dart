import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  late Directory temp;
  late Directory project;
  late Directory storage;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cantiere-frozen-');
    project = Directory(p.join(temp.path, 'workspace'))..createSync();
    storage = Directory(p.join(temp.path, 'private-state'));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('recovered source stays frozen after project content changes',
      () async {
    final request = _request(project.path, 'ui-one');
    final file = File(p.join(project.path, 'main.dart'));
    await file.writeAsString('original code');
    final before = _snapshot(project.path, 'original code');
    final first = WorkshopDurableFrozenSourceStore(root: storage);
    final handle = await first.persist(
      request: request,
      source: before,
      namespace: 'account-one',
    );
    expect(handle.key, startsWith('frozen-v1-'));

    await file.writeAsString('completely different source');
    final reopened = WorkshopDurableFrozenSourceStore(root: storage);
    final restored = await reopened.recover(
      request: _request(project.path, 'ui-two'),
      handle: handle,
      namespace: 'account-one',
    );
    expect(utf8.decode(restored.files.single.bytes), 'original code');
    expect(restored.totalBytes, utf8.encode('original code').length);
    expect(await file.readAsString(), 'completely different source');
  });

  test('restart recovers from ledger hash without an in-memory handle',
      () async {
    final request = _request(project.path, 'first-id');
    final source = _snapshot(project.path, 'frozen before app restart');
    final store = WorkshopDurableFrozenSourceStore(root: storage);
    final saved = await store.persist(
      request: request,
      source: source,
      namespace: 'local-account',
    );

    final reconstructed =
        WorkshopDurableFrozenSourceStore.handleFromPersistedDigest(
      request: _request(project.path, 'second-id'),
      sourceSha256: saved.sourceSha256,
      namespace: 'local-account',
    );
    expect(reconstructed.key, saved.key);
    final restored = await WorkshopDurableFrozenSourceStore(
      root: storage,
    ).recover(
      request: _request(project.path, 'third-id'),
      handle: reconstructed,
      namespace: 'local-account',
    );
    expect(utf8.decode(restored.files.single.bytes),
        'frozen before app restart');

    await expectLater(
      WorkshopDurableFrozenSourceStore(root: storage).recover(
        request: request,
        handle: WorkshopDurableFrozenSourceStore.handleFromPersistedDigest(
          request: request,
          sourceSha256: List<String>.filled(64, '0').join(),
          namespace: 'local-account',
        ),
        namespace: 'local-account',
      ),
      throwsStateError,
    );
  });

  test('invalid persisted fingerprint is rejected before I/O', () {
    expect(
      () => WorkshopDurableFrozenSourceStore.handleFromPersistedDigest(
        request: _request(project.path, 'ui'),
        sourceSha256: 'invalid',
        namespace: 'tenant',
      ),
      throwsArgumentError,
    );
  });

  test('source namespace is isolated and duplicate same bytes is idempotent',
      () async {
    final request = _request(project.path, 'first');
    final source = _snapshot(project.path, 'same code');
    final store = WorkshopDurableFrozenSourceStore(root: storage);
    final one = await store.persist(
      request: request, source: source, namespace: 'tenant-1',
    );
    final same = await store.persist(
      request: _request(project.path, 'next UI'),
      source: source,
      namespace: 'tenant-1',
    );
    expect(same.key, one.key);

    final other = await store.persist(
      request: request, source: source, namespace: 'tenant-2',
    );
    expect(other.key, isNot(one.key));
    await expectLater(
      store.recover(
        request: request,
        handle: one,
        namespace: 'tenant-2',
      ),
      throwsStateError,
    );
  });

  test('any corruption fails closed without recapturing current source',
      () async {
    final request = _request(project.path, 'ui');
    final store = WorkshopDurableFrozenSourceStore(root: storage);
    final handle = await store.persist(
      request: request,
      source: _snapshot(project.path, 'original'),
      namespace: 'tenant',
    );
    final saved = File(p.join(storage.path, handle.key + '.avxf'));
    await saved.writeAsBytes(utf8.encode('corrupted'), flush: true);
    await expectLater(
      store.recover(request: request, handle: handle, namespace: 'tenant'),
      throwsStateError,
    );
    await expectLater(
      store.persist(
        request: request,
        source: _snapshot(project.path, 'original'),
        namespace: 'tenant',
      ),
      throwsStateError,
    );
  });

  test('reject archive under the source workspace and symlink root', () async {
    final inside = WorkshopDurableFrozenSourceStore(
      root: Directory(p.join(project.path, '.source-cache')),
    );
    await expectLater(
      inside.persist(
        request: _request(project.path, 'ui'),
        source: _snapshot(project.path, 'source'),
        namespace: 'tenant',
      ),
      throwsStateError,
    );
    // A symlink root may redirect writes outside the private sandbox.
    if (!Platform.isWindows) {
      final redirected = Directory(p.join(temp.path, 'redirected'))
        ..createSync();
      final link = Link(p.join(temp.path, 'link-to-elsewhere'));
      await link.create(redirected.path);
      final linked = WorkshopDurableFrozenSourceStore(
        root: Directory(link.path),
      );
      await expectLater(
        linked.persist(
          request: _request(project.path, 'ui'),
          source: _snapshot(project.path, 'source'),
          namespace: 'tenant',
        ),
        throwsStateError,
      );
    }
  });

  test('symlink ancestor cannot redirect frozen store into workspace',
      () async {
    if (Platform.isWindows) return;
    final alias = Link(p.join(temp.path, 'workspace-alias'));
    await alias.create(project.path);
    final redirected = Directory(p.join(alias.path, 'snapshots'));
    final provider = WorkshopDurableFrozenSourceStore(root: redirected);
    await expectLater(
      provider.persist(
        request: _request(project.path, 'ui-alias'),
        source: _snapshot(project.path, 'PRIVATE SOURCE CONTENT'),
        namespace: 'tenant',
      ),
      throwsStateError,
    );
    expect(await redirected.exists(), isFalse);
    expect(await Directory(p.join(project.path, 'snapshots')).exists(),
        isFalse);
  });

  test('symlink workspace alias cannot hide overlap with source store',
      () async {
    if (Platform.isWindows) return;
    final alias = Link(p.join(temp.path, 'workspace-alias'));
    await alias.create(project.path);
    final provider = WorkshopDurableFrozenSourceStore(
      root: Directory(p.join(project.path, 'snapshots')),
    );
    await expectLater(
      provider.persist(
        request: _request(alias.path, 'ui-alias'),
        source: _snapshot(alias.path, 'PRIVATE SOURCE CONTENT'),
        namespace: 'tenant',
      ),
      throwsStateError,
    );
  });

  test('two differing snapshots produce distinct immutable references',
      () async {
    final request = _request(project.path, 'ui');
    final store = WorkshopDurableFrozenSourceStore(root: storage);
    final one = await store.persist(
      request: request,
      source: _snapshot(project.path, 'source a'),
      namespace: 'tenant',
    );
    final two = await store.persist(
      request: request,
      source: _snapshot(project.path, 'source b'),
      namespace: 'tenant',
    );
    expect(two.key, isNot(one.key));
    final restored = await store.recover(
      request: request, handle: one, namespace: 'tenant',
    );
    expect(utf8.decode(restored.files.single.bytes), 'source a');
  });

  test('snapshot identity leaks neither paths nor source code into filename',
      () async {
    final request = _request(project.path, 'ui');
    final store = WorkshopDurableFrozenSourceStore(root: storage);
    final handle = await store.persist(
      request: request,
      source: _snapshot(project.path, 'PRIVATE PROJECT CODE'),
      namespace: 'tenant',
    );
    expect(handle.key, matches(RegExp(r'^frozen-v1-[a-f0-9]{40}$')));
    expect(handle.key, isNot(contains('PRIVATE')));
    expect(handle.key, isNot(contains(project.path)));
    expect(handle.intentId, startsWith('build-v1-'));
  });
}

WorkshopBuildRequest _request(String projectPath, String id) =>
    WorkshopBuildRequest(
      id: id,
      projectId: 'generated-demo',
      projectPath: projectPath,
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _snapshot(String projectPath, String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return WorkshopBuildSourceSnapshot(
    rootPath: projectPath,
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(relativePath: 'lib/main.dart', bytes: bytes),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}
