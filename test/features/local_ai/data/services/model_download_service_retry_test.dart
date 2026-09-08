import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:dio/dio.dart';
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

class _RetryAdapter implements HttpClientAdapter {
  var calls = 0;
  final List<String?> ranges = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    ranges.add(options.headers[HttpHeaders.rangeHeader]?.toString());

    if (calls == 1) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'synthetic transient connection failure',
      );
    }

    return ResponseBody.fromBytes(
      const <int>[1, 2, 3, 4],
      HttpStatus.partialContent,
      headers: <String, List<String>>{
        HttpHeaders.contentRangeHeader: <String>['bytes 4-7/8'],
        HttpHeaders.contentLengthHeader: <String>['4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('model-download-retry-');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('transient retry preserves .part and reuses the same Range offset',
      () async {
    final model = AiModel(
      id: 'retry-model',
      displayName: 'retry-model',
      fileName: 'retry.gguf',
      downloadUrl: 'https://example.invalid/retry.gguf',
      version: '1.0.0',
      sizeBytes: 8,
      description: 'test model',
    );

    final modelsDir = Directory('${tempDir.path}/models')..createSync();
    final part = File('${modelsDir.path}/${model.fileName}.part');
    await part.writeAsBytes(_gguf, flush: true);

    final adapter = _RetryAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = ModelDownloadService(
      dio: dio,
      filePicker: _MockFilePicker(),
    );

    final downloaded = await service.downloadModel(model);

    expect(adapter.calls, 2);
    expect(adapter.ranges, <String?>['bytes=4-', 'bytes=4-']);
    expect(downloaded.isDownloaded, isTrue);
    expect(downloaded.validationStatus, ModelValidationStatus.validatedOk);
    expect(
      await File(downloaded.localPath!).readAsBytes(),
      <int>[..._gguf, 1, 2, 3, 4],
    );
    expect(await part.exists(), isFalse);
  });
}
