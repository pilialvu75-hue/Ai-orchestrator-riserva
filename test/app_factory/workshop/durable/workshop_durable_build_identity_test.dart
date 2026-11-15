import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_identity.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';

void main() {
  test('recovery identity is stable across UI ids and source iteration order',
      () {
    final left = WorkshopDurableBuildIdentity.forBuild(
      request: _request('first-ui-timestamp'),
      snapshot: _snapshot(<String, String>{
        'lib/main.dart': 'void main() {}',
        'pubspec.yaml': 'name: demo',
      }),
      generation: 2,
    );
    final right = WorkshopDurableBuildIdentity.forBuild(
      request: _request('new-ui-timestamp'),
      snapshot: _snapshot(<String, String>{
        'pubspec.yaml': 'name: demo',
        'lib/main.dart': 'void main() {}',
      }),
      generation: 2,
    );
    expect(left, right);
    expect(left, matches(RegExp(r'^durable-v2-[a-f0-9]{40}$')));
  });

  test('changing source bytes changes identity even if build options match',
      () {
    final before = WorkshopDurableBuildIdentity.forBuild(
      request: _request('ui-1'),
      snapshot: _snapshot(<String, String>{
        'lib/main.dart': 'void main() {}',
      }),
      generation: 1,
    );
    final after = WorkshopDurableBuildIdentity.forBuild(
      request: _request('ui-2'),
      snapshot: _snapshot(<String, String>{
        'lib/main.dart': 'void main() { print(1); }',
      }),
      generation: 1,
    );
    expect(after, isNot(before));
  });

  test('explicit new generation changes identity even for unchanged sources',
      () {
    final source = _snapshot(<String, String>{
      'lib/main.dart': 'void main() {}',
    });
    final first = WorkshopDurableBuildIdentity.forBuild(
      request: _request('ui-1'),
      snapshot: source,
      generation: 1,
    );
    final manualRetry = WorkshopDurableBuildIdentity.forBuild(
      request: _request('ui-2'),
      snapshot: source,
      generation: 2,
    );
    expect(manualRetry, isNot(first));
  });

  test('source path names are part of fingerprint without leaking source',
      () {
    final left = _snapshot(<String, String>{'lib/main.dart': 'private data'});
    final right = _snapshot(<String, String>{'lib/app.dart': 'private data'});
    final hash = WorkshopDurableBuildIdentity.sourceDigest(left);
    expect(hash, isNot(contains('private data')));
    expect(hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(hash, isNot(WorkshopDurableBuildIdentity.sourceDigest(right)));
  });

  test('empty source, unsafe paths, duplicates, and invalid generation fail',
      () {
    final empty = _snapshot(const <String, String>{});
    expect(
      () => WorkshopDurableBuildIdentity.sourceDigest(empty),
      throwsStateError,
    );
    final source = _snapshot(<String, String>{'lib/main.dart': 'hello'});
    expect(
      () => WorkshopDurableBuildIdentity.forBuild(
        request: _request('ui-1'),
        snapshot: source,
        generation: 0,
      ),
      throwsArgumentError,
    );
    for (final path in <String>['../main.dart', '/root/main.dart',
      'lib//main.dart', 'lib/./main.dart', r'lib\main.dart']) {
      expect(
        () => WorkshopDurableBuildIdentity.sourceDigest(
          _snapshot(<String, String>{path: 'hello'}),
        ),
        throwsStateError,
      );
    }
    final duplicate = WorkshopBuildSourceSnapshot(
      rootPath: '/workspace/demo',
      files: <WorkshopBuildSourceFile>[
        _file('lib/main.dart', 'one'),
        _file('lib/main.dart', 'two'),
      ],
      totalBytes: 6,
    );
    expect(
      () => WorkshopDurableBuildIdentity.sourceDigest(duplicate),
      throwsStateError,
    );
  });
}

WorkshopBuildRequest _request(String id) => WorkshopBuildRequest(
      id: id,
      projectId: 'demo',
      projectPath: '/workspace/demo',
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.remote,
    );

WorkshopBuildSourceSnapshot _snapshot(Map<String, String> entries) {
  final files = entries.entries
      .map((entry) => _file(entry.key, entry.value))
      .toList(growable: false);
  return WorkshopBuildSourceSnapshot(
    rootPath: '/workspace/demo',
    files: files,
    totalBytes: files.fold<int>(0, (size, file) => size + file.sizeInBytes),
  );
}

WorkshopBuildSourceFile _file(String relativePath, String content) =>
    WorkshopBuildSourceFile(
      relativePath: relativePath,
      bytes: Uint8List.fromList(utf8.encode(content)),
    );
