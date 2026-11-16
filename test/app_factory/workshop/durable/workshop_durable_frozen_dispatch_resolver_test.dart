import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_dispatch_resolver.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  late Directory root;
  late Directory workspace;
  late Directory archive;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('durable-resolver-');
    workspace = Directory(p.join(root.path, 'project'))..createSync();
    archive = Directory(p.join(root.path, 'private-archive'));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('unchanged active generation returns archived bytes, not live source',
      () async {
    final request = _request(workspace.path);
    final source = _snapshot(workspace.path, 'void main() { /* old */ }');
    final archived = WorkshopDurableFrozenSourceStore(root: archive);
    final storage = _HookedStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: storage);
    await archived.persist(
      request: request,
      source: source,
      namespace: 'local-owner',
    );
    final ticket = await ledger.reserveNew(request: request, source: source);

    final live = File(p.join(workspace.path, 'lib', 'main.dart'));
    await live.parent.create(recursive: true);
    await live.writeAsString('void main() { /* changed */ }');

    final resolver = WorkshopDurableFrozenDispatchResolver(
      ledger: ledger,
      frozenStore: archived,
      namespace: 'local-owner',
    );
    final actual = await resolver.resolve(
      request: _request(workspace.path, 'ui-after-restart'),
      correlationId: ticket.buildId + ':attempt:1',
    );
    expect(utf8.decode(actual.files.single.bytes),
        'void main() { /* old */ }');
    expect(await live.readAsString(), 'void main() { /* changed */ }');
    expect(storage.readsAfterHook, 0);
  });

  test('terminal checkpoint during disk recovery blocks stale dispatch',
      () async {
    final request = _request(workspace.path);
    final source = _snapshot(workspace.path, 'void main() {}');
    final archived = WorkshopDurableFrozenSourceStore(root: archive);
    final storage = _HookedStorage();
    final ledger = WorkshopDurableBuildGenerationLedger(storage: storage);
    await archived.persist(
      request: request,
      source: source,
      namespace: 'local-owner',
    );
    final ticket = await ledger.reserveNew(request: request, source: source);

    // The first resolver read sees ACTIVE. Simulate another durable actor
    // persisting a terminal state before the second read after disk I/O.
    storage.onRead = () {
      if (storage.readsAfterHook != 2) return;
      final payload = jsonDecode(storage.raw!) as Map<String, dynamic>;
      final records = payload['records'] as Map<String, dynamic>;
      final current = records[ticket.intentId] as Map<String, dynamic>;
      current['state'] = 'succeeded';
      storage.raw = jsonEncode(payload);
    };

    final resolver = WorkshopDurableFrozenDispatchResolver(
      ledger: ledger,
      frozenStore: archived,
      namespace: 'local-owner',
    );
    await expectLater(
      resolver.resolve(
        request: request,
        correlationId: ticket.buildId + ':attempt:1',
      ),
      throwsStateError,
    );
    expect(storage.readsAfterHook, 2);
    final restored = await ledger.recoverLatest(request);
    expect(restored!.state, WorkshopDurableGenerationState.succeeded);
  });
}

WorkshopBuildRequest _request(String path, [String id = 'request-1']) =>
    WorkshopBuildRequest(
      id: id,
      projectId: 'example-project',
      projectPath: path,
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _snapshot(String root, String contents) {
  final bytes = Uint8List.fromList(utf8.encode(contents));
  return WorkshopBuildSourceSnapshot(
    rootPath: root,
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(relativePath: 'lib/main.dart', bytes: bytes),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

final class _HookedStorage implements WorkshopDurableGenerationStorage {
  String? raw;
  int readsAfterHook = 0;
  void Function()? onRead;

  @override
  Future<String?> read() async {
    if (onRead != null) {
      readsAfterHook++;
      onRead!();
    }
    return raw;
  }

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
