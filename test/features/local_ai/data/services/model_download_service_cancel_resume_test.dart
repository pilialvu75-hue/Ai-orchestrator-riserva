import 'dart:async';
import 'dart:io';

import 'package:ai_orchestrator/core/error/exceptions.dart';
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
    tempDir = await Directory.systemTemp.createTemp('model-cancel-resume-');
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

  test('cancelled bytes stay in .part and next call resumes from them', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final model = AiModel(
      id: 'cancel-resume-model',
      displayName: 'cancel-resume-model',
      fileName: 'cancel-resume.gguf',
      downloadUrl:
          'http://${server.address.address}:${server.port}/cancel-resume.gguf',
      version: '1.0.0',
      sizeBytes: 12,
      description: 'test model',
    );

    final modelsDir = Directory('${tempDir.path}/models');
    await modelsDir.create(recursive: true);
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf, flush: true);

    final service = ModelDownloadService(filePicker: _MockFilePicker());
    final cancellationIssued = Completer<void>();
    String? resumedRange;
    var requestNumber = 0;

    final serverFuture = () async {
      await for (final request in server) {
        requestNumber++;

        if (requestNumber == 1) {
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 4-11/12',
          );
          request.response.contentLength = 8;
          request.response.add(const <int>[1, 2, 3, 4]);
          await request.response.flush();

          // The service starts with four persisted GGUF bytes. These four
          // streamed bytes move progress to 8/12; cancellation is issued from
          // that observed boundary, after the chunk has been queued to .part.
          await cancellationIssued.future;
          try {
            await request.response.close();
          } catch (_) {
            // Dio may close the socket immediately when cancellation is issued.
          }
          continue;
        }

        resumedRange = request.headers.value(HttpHeaders.rangeHeader);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 8-11/12',
        );
        request.response.contentLength = 4;
        request.response.add(const <int>[5, 6, 7, 8]);
        await request.response.close();
        break;
      }
    }();

    final firstDownload = service.downloadModel(
      model,
      onProgress: (progress) {
        if (progress >= 8 / 12 && !cancellationIssued.isCompleted) {
          service.cancelDownload(model.id);
          cancellationIssued.complete();
        }
      },
    );

    await expectLater(firstDownload, throwsA(isA<DownloadException>()));

    expect(await part.exists(), isTrue);
    expect(await part.length(), 8);
    expect(await part.readAsBytes(), <int>[..._gguf, 1, 2, 3, 4]);

    final downloaded = await service.downloadModel(model);
    await serverFuture;

    expect(resumedRange, 'bytes=8-');
    expect(downloaded.isDownloaded, isTrue);
    expect(downloaded.validationStatus, ModelValidationStatus.validatedOk);
    expect(
      await File(downloaded.localPath!).readAsBytes(),
      <int>[..._gguf, 1, 2, 3, 4, 5, 6, 7, 8],
    );
    expect(await part.exists(), isFalse);
  });
}
