import 'dart:io';

import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const _gguf = <int>[0x47, 0x47, 0x55, 0x46];

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
    tempDir = await Directory.systemTemp.createTemp('model-redirect-resume-');
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

  test('resume Range survives a redirect to the model object', () async {
    final redirectServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final objectServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    addTearDown(() async {
      await redirectServer.close(force: true);
      await objectServer.close(force: true);
    });

    final model = AiModel(
      id: 'redirect-resume-model',
      displayName: 'redirect-resume-model',
      fileName: 'redirect-resume.gguf',
      downloadUrl:
          'http://${redirectServer.address.address}:${redirectServer.port}/resolve/model.gguf',
      version: '1.0.0',
      sizeBytes: 12,
      description: 'test model',
    );

    final modelsDir = Directory('${tempDir.path}/models')..createSync();
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf, flush: true);

    String? rangeAtRedirect;
    String? rangeAtObject;

    final redirectFuture = () async {
      final request = await redirectServer.first;
      rangeAtRedirect = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://${objectServer.address.address}:${objectServer.port}/xet/model.gguf',
      );
      await request.response.close();
    }();

    final objectFuture = () async {
      final request = await objectServer.first;
      rangeAtObject = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 4-11/12',
      );
      request.response.contentLength = 8;
      request.response.add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      await request.response.close();
    }();

    final downloaded = await ModelDownloadService(
      filePicker: _MockFilePicker(),
    ).downloadModel(model);

    await Future.wait(<Future<void>>[redirectFuture, objectFuture]);

    expect(rangeAtRedirect, 'bytes=4-');
    expect(rangeAtObject, 'bytes=4-');
    expect(downloaded.isDownloaded, isTrue);
    expect(downloaded.validationStatus, ModelValidationStatus.validatedOk);
    expect(
      await File(downloaded.localPath!).readAsBytes(),
      <int>[..._gguf, 1, 2, 3, 4, 5, 6, 7, 8],
    );
    expect(await part.exists(), isFalse);
  });
}
