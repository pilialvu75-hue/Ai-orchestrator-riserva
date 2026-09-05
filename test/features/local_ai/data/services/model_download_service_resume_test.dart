import 'dart:io';

import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const _gguf = <int>[0x47, 0x47, 0x55, 0x46];

// Downloads do not use the file picker; inject it so these unit tests do not
// depend on native plugin registration.
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
    tempDir = await Directory.systemTemp.createTemp('model-download-resume-');
    originalHttpOverrides = HttpOverrides.current;
    // These tests exercise real HTTP against a loopback server.
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

  test('resumes an existing .part with an exact HTTP Range request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final model = _model(
      server,
      id: 'resume-model',
      fileName: 'resume.gguf',
      sizeBytes: 12,
    );
    final modelsDir = Directory('${tempDir.path}/models')..createSync();
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf);

    String? observedRange;
    final serverFuture = () async {
      final request = await server.first;
      observedRange = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 4-11/12',
      );
      request.response.contentLength = 8;
      request.response.add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      await request.response.close();
    }();

    final downloaded = await ModelDownloadService(filePicker: _MockFilePicker()).downloadModel(model);
    await serverFuture;

    expect(observedRange, 'bytes=4-');
    expect(downloaded.isDownloaded, isTrue);
    expect(downloaded.validationStatus, ModelValidationStatus.validatedOk);
    expect(await File(downloaded.localPath!).readAsBytes(), <int>[
      ..._gguf,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
    expect(await part.exists(), isFalse);
  });

  test('a server that ignores Range restarts safely instead of appending', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final model = _model(
      server,
      id: 'range-ignored-model',
      fileName: 'range-ignored.gguf',
      sizeBytes: 8,
    );
    final modelsDir = Directory('${tempDir.path}/models')..createSync();
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf);

    final serverFuture = () async {
      final request = await server.first;
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = 8;
      request.response.add(const <int>[0x47, 0x47, 0x55, 0x46, 9, 8, 7, 6]);
      await request.response.close();
    }();

    final downloaded = await ModelDownloadService(filePicker: _MockFilePicker()).downloadModel(model);
    await serverFuture;
    final bytes = await File(downloaded.localPath!).readAsBytes();

    expect(bytes, const <int>[0x47, 0x47, 0x55, 0x46, 9, 8, 7, 6]);
    expect(bytes.length, 8);
  });

  test('cancellation preserves the .part file for a later resume', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final model = _model(
      server,
      id: 'cancel-model',
      fileName: 'cancel.gguf',
      sizeBytes: 12,
    );
    final modelsDir = Directory('${tempDir.path}/models')..createSync();
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf);

    final service = ModelDownloadService(filePicker: _MockFilePicker());
    var cancelled = false;

    final future = service.downloadModel(
      model,
      onProgress: (progress) {
        if (!cancelled && progress >= (4 / 12)) {
          cancelled = true;
          service.cancelDownload(model.id);
        }
      },
    );

    await expectLater(future, throwsA(isA<DownloadException>()));

    expect(cancelled, isTrue);
    expect(await part.exists(), isTrue);
    expect(await part.readAsBytes(), _gguf);
    expect(
      await File('${tempDir.path}/models/${model.fileName}').exists(),
      isFalse,
    );
  });
}

AiModel _model(
  HttpServer server, {
  required String id,
  required String fileName,
  required int sizeBytes,
}) {
  return AiModel(
    id: id,
    displayName: id,
    fileName: fileName,
    downloadUrl: 'http://${server.address.address}:${server.port}/$fileName',
    version: '1.0.0',
    sizeBytes: sizeBytes,
    description: 'test model',
  );
}
