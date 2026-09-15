import 'dart:convert';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_service_factory.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  group('WorkshopInferenceServiceFactory', () {
    test('resolves the assigned Workshop model without Assistant selection', () async {
      final assistant = _model(
        id: 'phi3_5_mini',
        path: '/models/phi3.gguf',
      );
      final workshop = _model(
        id: 'starcoder_catalogue',
        runtimeModelId: 'starcoder2_3b',
        path: '/models/starcoder2.gguf',
      );

      final repository = _FakeLocalAiRepository(
        <AiModel>[assistant, workshop],
      );

      final resolved =
          await WorkshopInferenceServiceFactory.resolveInstalledModel(
        modelId: 'starcoder2_3b',
        repository: repository,
      );

      expect(resolved, same(workshop));
      expect(resolved, isNot(same(assistant)));
      expect(resolved?.localPath, '/models/starcoder2.gguf');
    });

    test('returns null when the assigned Workshop model is not installed', () async {
      final repository = _FakeLocalAiRepository(
        <AiModel>[
          _model(
            id: 'phi3_5_mini',
            path: '/models/phi3.gguf',
          ),
        ],
      );

      final resolved =
          await WorkshopInferenceServiceFactory.resolveInstalledModel(
        modelId: 'starcoder2_3b',
        repository: repository,
      );

      expect(resolved, isNull);
    });

    test('Workshop inference ignores Assistant runtime settings', () async {
      final sl = GetIt.asNewInstance();
      final workshop = _model(
        id: 'starcoder2_3b',
        path: '/models/starcoder2.gguf',
      );
      final localRuntime = _FakeLocalRuntime();

      sl.registerSingleton<LocalAiRepository>(
        _FakeLocalAiRepository(<AiModel>[workshop]),
      );
      sl.registerSingleton<LocalRuntimeProvider>(localRuntime);
      sl.registerSingleton<CloudRuntimeProvider>(
        CloudRuntimeProvider(
          sendQuery: (_, __) async => throw StateError('Cloud must not run'),
          supportedProviders: () => const <String>[],
          isProviderAvailable: (_) => false,
          providerDisplayName: ([_]) => '',
        ),
      );
      sl.registerSingleton<RuntimeSessionManager>(RuntimeSessionManager());

      // Deliberately no AiRuntimeSettingsService registration: Cantiere must
      // not consult the Assistant Local/Cloud/Hybrid preference.
      final service = WorkshopInferenceServiceFactory.create(
        modelId: 'starcoder2_3b',
        locator: sl,
      );

      await service
          .stream(
            const InferenceRequest(
              sessionId: 'workshop-runtime-isolation',
              prompt: 'test',
              modelId: 'starcoder2_3b',
            ),
          )
          .drain<void>();

      expect(localRuntime.calls, 1);
      await sl.reset();
    });

    test('Workshop web stack prefers ranked DuckDuckGo Lite results', () async {
      final requestedHosts = <String>[];
      final client = _FakeHttpClient((request) async {
        requestedHosts.add(request.url.host);
        expect(request.url.queryParameters['q'], 'best recipe apps features');

        return http.Response(
          '''
<html><body><table>
<tr>
  <td>1.</td>
  <td><a class="result-link" href="https://example.test/recipe-apps">Best recipe apps</a></td>
</tr>
<tr><td class="result-snippet">Meal planning, shopping lists and dietary filters.</td></tr>
</table></body></html>
''',
          200,
        );
      });

      final tool = WorkshopInferenceServiceFactory.createWorkshopWebSearchTool(
        client: client,
      );
      final result = await tool.execute(
        const <String, dynamic>{'query': 'best recipe apps features'},
      );

      expect(result.success, isTrue);
      expect(requestedHosts, <String>['lite.duckduckgo.com']);
      expect(result.output, contains('Best recipe apps'));
      expect(result.output, contains('Meal planning'));
      expect(result.output, contains('https://example.test/recipe-apps'));
    });
  });
}

AiModel _model({
  required String id,
  required String path,
  String? runtimeModelId,
}) {
  return AiModel(
    id: id,
    displayName: id,
    fileName: '$id.gguf',
    downloadUrl: 'https://example.invalid/$id.gguf',
    version: '1.0.0',
    sizeBytes: 1024,
    description: 'test model',
    isDownloaded: true,
    localPath: path,
    validationStatus: ModelValidationStatus.validatedOk,
    runtimeModelId: runtimeModelId,
  );
}

final class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

final class _FakeLocalRuntime extends LocalRuntimeProvider {
  int calls = 0;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls += 1;
  }
}

final class _FakeLocalAiRepository implements LocalAiRepository {
  _FakeLocalAiRepository(this.models);

  final List<AiModel> models;

  @override
  Future<Either<Failure, List<AiModel>>> getAvailableModels() async =>
      Right<Failure, List<AiModel>>(models);

  @override
  Future<Either<Failure, AiModel>> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel>> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel?>> importLocalModel({
    String? existingModelId,
  }) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> cancelDownload(String modelId) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> deleteModel(String modelId) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, List<AiModel>>> checkForUpdates() =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, AiModel?>> getSelectedModel() =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, void>> selectModel(String modelId) =>
      throw UnimplementedError();
}
