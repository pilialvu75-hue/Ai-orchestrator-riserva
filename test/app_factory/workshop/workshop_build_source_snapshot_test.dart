import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('captures text and binary source while excluding secrets and outputs',
      () async {
    final root = await Directory.systemTemp.createTemp('workshop-build-source-');
    addTearDown(() => root.delete(recursive: true));

    await _write(root, 'pubspec.yaml', 'name: generated_app\n');
    await _write(root, 'lib/main.dart', 'void main() {}\n');
    final asset = File(p.join(root.path, 'assets', 'icon.bin'));
    await asset.parent.create(recursive: true);
    await asset.writeAsBytes(<int>[0, 255, 13, 10, 42]);

    await _write(root, '.env', 'DO_NOT_EXPORT=1\n');
    await _write(root, 'android/local.properties', 'sdk.dir=/private/sdk\n');
    await _write(root, 'android/key.properties', 'storePassword=secret\n');
    await _write(root, 'android/release.jks', 'secret signing material\n');
    await _write(root, '.dart_tool/package_config.json', '{}');
    await _write(root, 'build/app/output.txt', 'transient');

    final snapshot = await const WorkshopBuildSourceSnapshotter().capture(
      root.path,
    );

    expect(
      snapshot.files.map((file) => file.relativePath),
      <String>['assets/icon.bin', 'lib/main.dart', 'pubspec.yaml'],
    );
    expect(snapshot.contains('assets/icon.bin'), isTrue);
    expect(snapshot.files.first.bytes, <int>[0, 255, 13, 10, 42]);
    expect(snapshot.contains('.env'), isFalse);
    expect(snapshot.contains('android/local.properties'), isFalse);
    expect(snapshot.contains('android/key.properties'), isFalse);
    expect(snapshot.contains('android/release.jks'), isFalse);
    expect(snapshot.contains('.dart_tool/package_config.json'), isFalse);
    expect(snapshot.contains('build/app/output.txt'), isFalse);
  });

  test('fails closed when a single source file exceeds its limit', () async {
    final root = await Directory.systemTemp.createTemp('workshop-build-source-');
    addTearDown(() => root.delete(recursive: true));

    await _write(root, 'pubspec.yaml', 'name: generated_app\n');
    await _write(root, 'lib/main.dart', '12345');

    const snapshotter = WorkshopBuildSourceSnapshotter(maxFileBytes: 4);

    await expectLater(
      snapshotter.capture(root.path),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('per-file limit'),
        ),
      ),
    );
  });

  test('fails closed when the workspace is empty', () async {
    final root = await Directory.systemTemp.createTemp('workshop-build-source-');
    addTearDown(() => root.delete(recursive: true));

    await expectLater(
      const WorkshopBuildSourceSnapshotter().capture(root.path),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('no exportable files'),
        ),
      ),
    );
  });
}

Future<void> _write(Directory root, String relativePath, String content) async {
  final file = File(
    p.joinAll(<String>[root.path, ...relativePath.split('/')]),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
