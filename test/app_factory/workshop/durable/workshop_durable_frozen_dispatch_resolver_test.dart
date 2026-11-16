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
  late Directory privateArchive;
  late _MemoryStorage storage;
  late WorkshopDurableBuildGenerationLedger ledger;
  late WorkshopDurableFrozenSourceStore frozen;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('durable-resolver-');
    workspace = Directory(p.join(root.path, 'workspace'))
      ..createSync();
    privateArchive = Directory(p.join(root.path, 'app-private'));
    storage = _MemoryStorage();
    ledger = WorkshopDurableBuildGenerationLedger(storage: storage);
    frozen = WorkshopDurableFrozenSourceStore(root: privateArchive);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('frozen payload resolves only for the active attempt', () async {
    final request = _request(workspace.path);
    final source = _source(workspace.path);
    await frozen.persist(
      request: request, source: source, namespace: 'owner-one',
    );
    final ticket = await ledger.reserveNew(
      request: request, source: source,
    );
    final resolver = WorkshopDurableFrozenDispatchResolver(
      ledger: ledger, frozenStore: frozen, namespace: 'owner-one',
    );
    final result = await resolver.resolve(
      request: request,
      correlationId: ticket.buildId + ':attempt:1',
    );
    expect(utf8.decode(result.files.single.bytes), 'void main() {}');

    await expectLater(
      resolver.resolve(
        request: request,
        correlationId: ticket.buildId + ':attempt:01',
      ),
      throwsStateError,
    );
    await ledger.markTerminal(
      request: request, expectedBuildId: ticket.buildId, succeeded: true,
    );
    await expectLater(
      resolver.resolve(
        request: request,
        correlationId: ticket.buildId + ':attempt:1',
      ),
      throwsStateError,
    );
  });

  test('terminal transition during frozen read fails closed', () async {
    final request = _request(workspace.path);
    final source = _source(workspace.path);
    await frozen.persist(
      request: request, source: source, namespace: 'owner-one',
    );
    final ticket = await ledger.reserveNew(
      request: request, source: source,
    );
    final activeJournal = storage.raw!;
    await ledger.markTerminal(
      request: request, expectedBuildId: ticket.buildId, succeeded: false,
    );
    final failedJournal = storage.raw!;

    // First read returns ACTIVE. The second read, after immutable disk I/O,
    // returns FAILED. Neither read uses a mutable in-memory preference cache.
    final raceStorage = _JournalTransitionStorage(
      before: activeJournal, after: failedJournal,
    );
    final resolver = WorkshopDurableFrozenDispatchResolver(
      ledger: WorkshopDurableBuildGenerationLedger(storage: raceStorage),
      frozenStore: WorkshopDurableFrozenSourceStore(root: privateArchive),
      namespace: 'owner-one',
    );

    await expectLater(
      resolver.resolve(
        request: request,
        correlationId: ticket.buildId + ':attempt:2',
      ),
      throwsStateError,
    );
    expect(raceStorage.readCount, 2);
  });
}

WorkshopBuildRequest _request(String path) => WorkshopBuildRequest(
      id: 'test-request',
      projectId: 'project-one',
      projectPath: path,
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _source(String workspacePath) {
  final bytes = Uint8List.fromList(utf8.encode('void main() {}'));
  return WorkshopBuildSourceSnapshot(
    rootPath: workspacePath,
    files: <WorkshopBuildSourceFile>[
      WorkshopBuildSourceFile(
        relativePath: 'lib/main.dart', bytes: bytes,
      ),
    ],
    totalBytes: bytes.lengthInBytes,
  );
}

final class _MemoryStorage implements WorkshopDurableGenerationStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String data) async {
    raw = data;
    return true;
  }
}

final class _JournalTransitionStorage
    implements WorkshopDurableGenerationStorage {
  _JournalTransitionStorage({required this.before, required this.after});

  final String before;
  final String after;
  int readCount = 0;

  @override
  Future<String?> read() async {
    readCount++;
    return readCount == 1 ? before : after;
  }

  @override
  Future<bool> write(String data) async =>
      throw StateError('Read-only race fixture');
}
