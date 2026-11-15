import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_preflight.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  late Directory root;
  late Directory workspace;
  late Directory archive;
  late _MemoryLedgerStorage memory;
  late WorkshopDurableBuildGenerationLedger ledger;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('durable-preflight-');
    workspace = Directory(p.join(root.path, 'generated'))..createSync();
    archive = Directory(p.join(root.path, 'private'));
    memory = _MemoryLedgerStorage();
    ledger = WorkshopDurableBuildGenerationLedger(storage: memory);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('restart resumes frozen source, never new workspace bytes', () async {
    var captures = 0;
    var liveCode = 'void main() { print("original"); }';
    final first = WorkshopDurableBuildPreflight(
      ledger: ledger,
      frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
      namespace: 'owner-local',
      capture: (path) async {
        captures++;
        return _source(path, liveCode);
      },
    );
    final prepared = await first.beginNew(_request(workspace.path, 'ui-1'));
    expect(prepared.reservation.generation, 1);
    expect(captures, 1);
    liveCode = 'void main() { print("modified"); }';

    final reopened = WorkshopDurableBuildPreflight(
      ledger: WorkshopDurableBuildGenerationLedger(storage: memory),
      frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
      namespace: 'owner-local',
      capture: (path) async {
        fail('recovery must never recapture a mutated project');
      },
    );
    final recovered = await reopened.recoverPending(
      _request(workspace.path, 'ui-2'),
    );
    expect(recovered?.reservation.buildId, prepared.reservation.buildId);
    expect(recovered?.sourceHandle.key, prepared.sourceHandle.key);
    final frozen = await reopened.loadFrozenForDispatch(
      request: _request(workspace.path, 'ui-3'),
      prepared: recovered!,
    );
    expect(utf8.decode(frozen.files.single.bytes),
        'void main() { print("original"); }');
    expect(captures, 1);
    await expectLater(
      reopened.beginNew(_request(workspace.path, 'ui-4')),
      throwsA(isA<TestFailure>()),
    );
  });

  test('new explicit generation after persisted terminal gets new content',
      () async {
    var text = 'void main() {}';
    final service = _service(
      workspace: workspace,
      archive: archive,
      ledger: ledger,
      capture: (path) async => _source(path, text),
    );
    final first = await service.beginNew(_request(workspace.path, 'ui-1'));
    await ledger.markTerminal(
      request: _request(workspace.path, 'ui-2'),
      expectedBuildId: first.reservation.buildId,
      succeeded: false,
    );
    expect(await service.recoverPending(_request(workspace.path, 'ui-3')),
        isNull);
    text = 'void main() { print("new source"); }';
    final second = await service.beginNew(_request(workspace.path, 'ui-4'));
    expect(second.reservation.generation, 2);
    expect(second.reservation.buildId, isNot(first.reservation.buildId));
    expect(second.sourceHandle.key, isNot(first.sourceHandle.key));
    await expectLater(
      service.loadFrozenForDispatch(
        request: _request(workspace.path, 'ui-5'),
        prepared: first,
      ),
      throwsStateError,
    );
  });

  test('missing frozen source fails closed without a new generation', () async {
    final service = _service(
      workspace: workspace,
      archive: archive,
      ledger: ledger,
      capture: (path) async => _source(path, 'void main() {}'),
    );
    final prepared = await service.beginNew(_request(workspace.path, 'ui-1'));
    await File(p.join(archive.path, prepared.sourceHandle.key + '.avxf'))
        .delete();
    await expectLater(
      service.recoverPending(_request(workspace.path, 'ui-2')),
      throwsStateError,
    );
    expect((await ledger.recoverLatest(_request(workspace.path, 'ui-3')))
        ?.generation, 1);
    await expectLater(
      service.beginNew(_request(workspace.path, 'ui-4')),
      throwsStateError,
    );
  });

  test('invalid Android entrypoint prevents reservation', () async {
    final service = _service(
      workspace: workspace,
      archive: archive,
      ledger: ledger,
      capture: (path) async => _source(path, '', relative: 'README.md'),
    );
    await expectLater(
      service.beginNew(_request(workspace.path, 'ui')),
      throwsStateError,
    );
    expect(await ledger.recoverLatest(_request(workspace.path, 'ui')),
        isNull);
  });

  test('wrong owner namespace cannot restore active execution', () async {
    final first = _service(
      workspace: workspace,
      archive: archive,
      ledger: ledger,
      capture: (path) async => _source(path, 'void main() {}'),
    );
    await first.beginNew(_request(workspace.path, 'ui-1'));
    final other = WorkshopDurableBuildPreflight(
      ledger: ledger,
      frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
      namespace: 'different-owner',
      capture: (path) async => _source(path, 'void main() {}'),
    );
    await expectLater(
      other.recoverPending(_request(workspace.path, 'ui-2')),
      throwsStateError,
    );
  });
}

WorkshopDurableBuildPreflight _service({
  required Directory workspace,
  required Directory archive,
  required WorkshopDurableBuildGenerationLedger ledger,
  required WorkshopDurableSourceCapture capture,
}) =>
    WorkshopDurableBuildPreflight(
      ledger: ledger,
      frozenSources: WorkshopDurableFrozenSourceStore(root: archive),
      capture: capture,
      namespace: 'owner-local',
    );

WorkshopBuildRequest _request(String workspace, String id) =>
    WorkshopBuildRequest(
      id: id,
      projectId: 'demo',
      projectPath: workspace,
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _source(
  String root,
  String text, {
  String relative = 'lib/main.dart',
}) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return WorkshopBuildSourceSnapshot(
    rootPath: root,
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(relativePath: relative, bytes: bytes),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

final class _MemoryLedgerStorage implements WorkshopDurableGenerationStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
