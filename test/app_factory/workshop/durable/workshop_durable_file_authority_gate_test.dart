import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_file_authority_gate.dart';

void main() {
  late Directory privateRoot;

  setUp(() async {
    privateRoot = await Directory.systemTemp.createTemp('durable-authority-');
  });

  tearDown(() async {
    if (await privateRoot.exists()) {
      await privateRoot.delete(recursive: true);
    }
  });

  WorkshopDurableFileAuthorityGate gate([String scope = 'workshop-owner']) =>
      WorkshopDurableFileAuthorityGate(
        privateRoot: privateRoot,
        schedulerScope: scope,
      );

  test('concurrent instances in one isolate cannot both enter', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = gate().run(() async {
      entered.complete();
      await release.future;
      return 7;
    });
    await entered.future;

    var secondEntered = false;
    await expectLater(
      gate().run(() async {
        secondEntered = true;
        return 9;
      }),
      throwsStateError,
    );
    expect(secondEntered, isFalse);

    release.complete();
    expect(await first, 7);
    expect(await gate().run(() async => 9), 9);
  });

  test('another Dart isolate is denied while owner is active', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = gate().run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;

    final rootPath = privateRoot.path;
    final result = await Isolate.run(() async {
      final otherIsolate = WorkshopDurableFileAuthorityGate(
        privateRoot: Directory(rootPath),
        schedulerScope: 'workshop-owner',
      );
      try {
        await otherIsolate.run(() async => 1);
        return 'incorrectly-acquired';
      } on StateError {
        return 'blocked';
      }
    });
    expect(result, 'blocked');

    release.complete();
    await first;
    expect(await gate().run(() async => 2), 2);
  });

  test('an orphaned file fails closed without automatic lock stealing',
      () async {
    final owner = gate();
    await File(owner.lockPath).writeAsString('unknown or crashed owner');

    var called = false;
    await expectLater(
      owner.run(() async {
        called = true;
      }),
      throwsStateError,
    );
    expect(called, isFalse);
    expect(
      await File(owner.lockPath).readAsString(),
      'unknown or crashed owner',
    );
  });

  test('action failure releases a verifiably owned gate', () async {
    final owner = gate();
    await expectLater(
      owner.run<void>(() async => throw StateError('local failure')),
      throwsStateError,
    );
    expect(await File(owner.lockPath).exists(), isFalse);
    expect(await gate().run(() async => 3), 3);
  });

  test('tampered ownership never removes the replacement record', () async {
    final owner = gate();
    await expectLater(
      owner.run(() async {
        await File(owner.lockPath).writeAsString('different owner');
      }),
      throwsStateError,
    );
    expect(await File(owner.lockPath).readAsString(), 'different owner');
  });

  test('different scheduler scopes use different gates', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = gate('workspace-a').run(() async {
      entered.complete();
      await release.future;
      return 1;
    });
    await entered.future;
    expect(await gate('workspace-b').run(() async => 2), 2);
    release.complete();
    expect(await first, 1);
  });

  test('missing private root cannot be used', () async {
    final missing = WorkshopDurableFileAuthorityGate(
      privateRoot: Directory('${privateRoot.path}/absent'),
      schedulerScope: 'scope',
    );
    await expectLater(missing.run(() async => 1), throwsStateError);
  });

  test('empty scope is rejected before touching the filesystem', () {
    expect(
      () => WorkshopDurableFileAuthorityGate(
        privateRoot: privateRoot,
        schedulerScope: '  ',
      ),
      throwsArgumentError,
    );
  });
}
