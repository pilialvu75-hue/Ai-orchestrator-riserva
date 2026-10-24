import 'dart:io';

import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const _completeGguf = <int>[0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4];

class _MockFilePicker extends Mock implements FilePicker {}

class _TestPathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TestPathProviderPlatform(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;
  late HttpOverrides? originalHttpOverrides;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('model-download-416-');
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    HttpOverrides.global = originalHttpOverrides;
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('HTTP 416 promotes an exact valid GGUF .part without redownloading',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final model = AiModel(
      id: 'range-complete-model',
      displayName: 'range-complete-model',
      fileName: 'range-complete.gguf',
      downloadUrl:
          'http://${server.address.address}:${server.port}/range-complete.gguf',
      version: '1.0.0',
      sizeBytes: _completeGguf.length,
      description: 'test model',
    );

    final modelsDir = Directory('${tempDir.path}/models');
    await modelsDir.create(recursive: true);
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_completeGguf, flush: true);

    var requestCount = 0;
    String? observedRange;
    final serverFuture = () async {
      final request = await server.first;
      requestCount++;
      observedRange = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${_completeGguf.length}',
      );
      request.response.contentLength = 0;
      await request.response.close();
    }();

    final downloaded = await ModelDownloadService(
      filePicker: _MockFilePicker(),
    ).downloadModel(model);
    await serverFuture;

    expect(requestCount, 1);
    expect(observedRange, 'bytes=${_completeGguf.length}-');
    expect(downloaded.isDownloaded, isTrue);
    expect(downloaded.validationStatus, ModelValidationStatus.validatedOk);
    expect(await File(downloaded.localPath!).readAsBytes(), _completeGguf);
    expect(await part.exists(), isFalse);
  });

  for (final scenario in <String, String?>{
    'complete': 'bytes 0-0/8',
    'incomplete': 'bytes 0-0/12',
    'oversized': 'bytes 0-0/4',
    'malformed': 'bytes */8',
    'ignored': null,
    'invalid-gguf': 'bytes 0-0/8',
  }.entries) {
    test('416 without total: ${scenario.key} preserves integrity', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bytes = scenario.key == 'invalid-gguf'
          ? List<int>.filled(8, 0)
          : _completeGguf;
      final modelsDir = await Directory('${tempDir.path}/models').create();
      final finalFile = File('${modelsDir.path}/probe.gguf');
      final part = File('${finalFile.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      final ranges = <String?>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (range == 'bytes=8-') {
          request.response.statusCode = 416;
          request.response.contentLength = 0;
        } else if (range == 'bytes=0-0') {
          request.response.statusCode = scenario.key == 'ignored' ? 200 : 206;
          if (scenario.value != null) {
            request.response.headers.set(HttpHeaders.contentRangeHeader, scenario.value!);
          }
          request.response.contentLength = 1;
          request.response.add([bytes.first]);
        } else {
          request.response.statusCode = 400;
        }
        await request.response.close();
      });
      final model = AiModel(
        id: 'probe-model',
        displayName: 'probe-model',
        fileName: 'probe.gguf',
        downloadUrl: 'http://${server.address.address}:${server.port}/probe.gguf',
        version: '1.0.0',
        // Deliberately wrong estimate: it cannot establish HTTP completion.
        sizeBytes: 12,
        description: 'synthetic test',
      );
      final operation = ModelDownloadService(
        filePicker: _MockFilePicker(),
      ).downloadModel(model);
      if (scenario.key == 'complete') {
        final downloaded = await operation;
        expect(downloaded.isDownloaded, isTrue);
        expect(await finalFile.readAsBytes(), bytes);
        expect(await part.exists(), isFalse);
      } else {
        await expectLater(operation, throwsA(anything));
        expect(await part.readAsBytes(), bytes);
        expect(await finalFile.exists(), isFalse);
      }
      expect(ranges, ['bytes=8-', 'bytes=0-0']);
    });
  }
}
