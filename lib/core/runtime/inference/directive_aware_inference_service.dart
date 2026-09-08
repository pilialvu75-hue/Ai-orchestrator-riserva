import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

/// Compatibility wrapper that adds explicit route directives without changing
/// the battle-tested Local inference implementation.
///
/// Three instances of the existing [InferenceService] share the same runtime
/// providers and model/session infrastructure:
///
/// - default: follows persisted Local / Cloud / Hybrid mode;
/// - local-only: always enters the existing Local branch;
/// - cloud-only: always enters the existing Cloud branch.
///
/// This keeps native/FFI behaviour untouched while allowing the caller to own
/// the routing decision. In particular:
///
/// - explicit Cloud chat can bypass the Orchestrator;
/// - Hybrid Hannibal can make the Local/Cloud decision itself.
final class DirectiveAwareInferenceService extends InferenceService {
  DirectiveAwareInferenceService({
    required Future<AiModel?> Function() loadSelectedModel,
    required Future<AiRuntimeMode> Function() loadRuntimeMode,
    required LocalRuntimeProvider runtimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
    required RuntimeSessionManager sessionManager,
    Tool? webSearchTool,
  })  : _localOnlyService = InferenceService(
          loadSelectedModel: loadSelectedModel,
          loadRuntimeMode: () async => AiRuntimeMode.local,
          runtimeProvider: runtimeProvider,
          cloudRuntimeProvider: cloudRuntimeProvider,
          sessionManager: sessionManager,
          webSearchTool: webSearchTool,
        ),
        _cloudOnlyService = InferenceService(
          loadSelectedModel: loadSelectedModel,
          loadRuntimeMode: () async => AiRuntimeMode.cloud,
          runtimeProvider: runtimeProvider,
          cloudRuntimeProvider: cloudRuntimeProvider,
          sessionManager: sessionManager,
          webSearchTool: webSearchTool,
        ),
        super(
          loadSelectedModel: loadSelectedModel,
          loadRuntimeMode: loadRuntimeMode,
          runtimeProvider: runtimeProvider,
          cloudRuntimeProvider: cloudRuntimeProvider,
          sessionManager: sessionManager,
          webSearchTool: webSearchTool,
        );

  final InferenceService _localOnlyService;
  final InferenceService _cloudOnlyService;

  @override
  TokenStream stream(InferenceRequest request) {
    switch (request.routeDirective) {
      case InferenceRouteDirective.runtimeDefault:
        return super.stream(request);
      case InferenceRouteDirective.localOnly:
        return _localOnlyService.stream(request);
      case InferenceRouteDirective.cloudOnly:
        return _cloudOnlyService.stream(request);
    }
  }

  @override
  void cancel(String sessionId) {
    // Only one delegate owns a given request, but cancellation is intentionally
    // broadcast so a caller does not need to remember which route was chosen.
    super.cancel(sessionId);
    _localOnlyService.cancel(sessionId);
    _cloudOnlyService.cancel(sessionId);
  }
}
