import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_execution_guard.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

import 'workshop_airlab_client.dart';
import 'workshop_airlab_contract.dart';
import 'workshop_airlab_staging_materializer.dart';

/// Maps a generic Cantiere task into the stable AIrLab protocol.
///
/// The mapper deliberately forwards only explicit AIrLab metadata. It does not
/// serialize the complete Workshop task or arbitrary execution context, which
/// keeps provider credentials and unrelated project state out of the transport.
final class WorkshopAirLabTaskRequestMapper {
  const WorkshopAirLabTaskRequestMapper();

  WorkshopAirLabTaskRequest map({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionContext context,
  }) {
    final family = _stringMetadata(task.metadata, 'airlabTaskFamily') ?? 'software';
    final inputs = _inputs(task.metadata['airlabInputs']);
    final requestedArtifacts = _strings(task.metadata['airlabRequestedArtifacts']);
    final explicitKind = _stringMetadata(task.metadata, 'airlabTaskKind');

    final requestContext = <String, dynamic>{};
    if (task.metadata.containsKey('airlabPrinterProfile')) {
      requestContext['printer_profile'] = task.metadata['airlabPrinterProfile'];
    }

    return WorkshopAirLabTaskRequest(
      task: task.objective,
      projectId: _stringMetadata(context.metadata, 'projectId') ??
          _stringMetadata(task.metadata, 'projectId') ??
          'default',
      target: _stringMetadata(task.metadata, 'airlabTarget') ??
          _stringMetadata(context.metadata, 'target') ??
          'web',
      mode: _modeFor(task.kind),
      taskFamily: family,
      taskKind: explicitKind ??
          _kindFor(
            family: family,
            kind: task.kind,
            inputs: inputs,
            requestedArtifacts: requestedArtifacts,
          ),
      inputs: inputs,
      requestedArtifacts: requestedArtifacts,
      context: requestContext,
    );
  }

  static String _modeFor(WorkshopTaskKind kind) {
    switch (kind) {
      case WorkshopTaskKind.analysis:
      case WorkshopTaskKind.planning:
      case WorkshopTaskKind.review:
        return 'plan';
      case WorkshopTaskKind.debugging:
        return 'repair';
      case WorkshopTaskKind.codeGeneration:
      case WorkshopTaskKind.codeModification:
      case WorkshopTaskKind.test:
      case WorkshopTaskKind.lint:
      case WorkshopTaskKind.build:
      case WorkshopTaskKind.documentation:
      case WorkshopTaskKind.integration:
        return 'implement';
    }
  }

  static String _kindFor({
    required String family,
    required WorkshopTaskKind kind,
    required List<WorkshopAirLabTaskInput> inputs,
    required List<String> requestedArtifacts,
  }) {
    switch (family) {
      case 'software':
        if (kind == WorkshopTaskKind.debugging) return 'software.repair';
        if (kind == WorkshopTaskKind.review) return 'software.review';
        return 'software.build';
      case 'web':
        if (kind == WorkshopTaskKind.debugging) return 'web.repair';
        if (kind == WorkshopTaskKind.review) return 'web.review';
        return 'web.build';
      case 'cad':
        if (inputs.any((input) => input.kind == 'image' || input.kind == 'drawing')) {
          return 'cad.reconstruct';
        }
        if (kind == WorkshopTaskKind.debugging || kind == WorkshopTaskKind.review) {
          return 'cad.revise';
        }
        return 'cad.model';
      case 'manufacturing':
        return requestedArtifacts.contains('gcode')
            ? 'manufacturing.slice'
            : 'manufacturing.validate';
      default:
        throw ArgumentError.value(
          family,
          'airlabTaskFamily',
          'Unsupported AIrLab task family.',
        );
    }
  }

  static List<WorkshopAirLabTaskInput> _inputs(Object? raw) {
    if (raw == null) return const <WorkshopAirLabTaskInput>[];
    if (raw is! List) {
      throw const FormatException('airlabInputs must be a list.');
    }

    return List<WorkshopAirLabTaskInput>.unmodifiable(
      raw.map((entry) {
        if (entry is! Map) {
          throw const FormatException('Each airlabInputs entry must be an object.');
        }
        final map = Map<String, dynamic>.from(entry);
        final kind = map['kind']?.toString().trim() ?? '';
        final reference = map['reference']?.toString().trim() ?? '';
        if (kind.isEmpty || reference.isEmpty) {
          throw const FormatException(
            'AIrLab input kind and reference must be non-empty.',
          );
        }
        final metadata = map['metadata'];
        if (metadata != null && metadata is! Map) {
          throw const FormatException('AIrLab input metadata must be an object.');
        }
        return WorkshopAirLabTaskInput(
          kind: kind,
          reference: reference,
          metadata: metadata == null
              ? const <String, dynamic>{}
              : Map<String, dynamic>.from(metadata),
        );
      }),
    );
  }

  static List<String> _strings(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is! List) {
      throw const FormatException('AIrLab artifact list must be a list.');
    }
    final values = <String>[];
    for (final item in raw) {
      final value = item.toString().trim().toLowerCase();
      if (value.isNotEmpty && !values.contains(value)) {
        values.add(value);
      }
    }
    return List<String>.unmodifiable(values);
  }

  static String? _stringMetadata(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is! String) return null;
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }
}

/// Cantiere executor that delegates an already-authorized task to AIrLab.
///
/// This adapter is intentionally conservative:
/// - it never chooses a different resource;
/// - it never silently falls back to a Cloud provider;
/// - it probes AIrLab before each execution;
/// - it validates advertised task/input/artifact capabilities;
/// - proposed file operations are treated as untrusted input;
/// - it never promotes staged AIrLab output to the real repository.
final class WorkshopAirLabTaskExecutor implements WorkshopTaskExecutor {
  WorkshopAirLabTaskExecutor({
    required WorkshopAirLabClient client,
    this.resource = WorkshopTaskResource.local,
    this.providerId = 'airlab',
    WorkshopAirLabTaskRequestMapper mapper = const WorkshopAirLabTaskRequestMapper(),
    WorkshopAirLabStagingMaterializer? stagingMaterializer,
  })  : _client = client,
        _mapper = mapper,
        _stagingMaterializer = stagingMaterializer;

  final WorkshopAirLabClient _client;
  final WorkshopAirLabTaskRequestMapper _mapper;
  final WorkshopAirLabStagingMaterializer? _stagingMaterializer;
  WorkshopAirLabProbe? _lastProbe;

  @override
  String get executorId => 'airlab';

  @override
  final WorkshopTaskResource resource;

  @override
  final String? providerId;

  @override
  bool get isAvailable => _lastProbe?.isAvailable == true;

  WorkshopAirLabProbe? get lastProbe => _lastProbe;

  Future<WorkshopAirLabProbe> refreshAvailability() async {
    final probe = await _client.probe();
    _lastProbe = probe;
    return probe;
  }

  @override
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionGuardDecision guardDecision,
    required WorkshopTaskExecutionContext context,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    final guardFailure = _validateGuard(task, guardDecision);
    if (guardFailure != null) return guardFailure;

    onProgress?.call(
      WorkshopTaskExecutionProgress(
        taskId: task.id,
        phase: 'airlab_probe',
        message: 'Checking AIrLab availability.',
      ),
    );

    final probe = await refreshAvailability();
    if (!probe.isAvailable) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab is ${probe.availability.name}: ${probe.reason ?? 'no reason provided'}.',
        metadata: <String, dynamic>{
          'executor': executorId,
          'availability': probe.availability.name,
        },
      );
    }

    try {
      final request = _mapper.map(task: task, context: context);
      final capabilities = await _client.capabilities();
      final capabilityError = _validateCapabilities(capabilities, request);
      if (capabilityError != null) {
        return WorkshopTaskExecutionResult(
          taskId: task.id,
          status: WorkshopTaskStatus.failed,
          message: capabilityError,
          metadata: <String, dynamic>{
            'executor': executorId,
            'engineId': capabilities.engineId,
          },
        );
      }

      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'airlab_execute',
          message: 'AIrLab accepted the task contract.',
        ),
      );

      final response = await _client.submitTask(request);
      if (response.status != 'ok') {
        return WorkshopTaskExecutionResult(
          taskId: task.id,
          status: WorkshopTaskStatus.failed,
          message: 'AIrLab returned status ${response.status}.',
          metadata: <String, dynamic>{
            'executor': executorId,
            'requestId': response.requestId,
            'engineId': response.engineId,
          },
        );
      }

      WorkshopAirLabStagingResult? stagingResult;
      WorkshopTaskCheckpoint? checkpoint;
      if (response.operations.isNotEmpty) {
        final materializer = _stagingMaterializer;
        if (materializer == null) {
          return WorkshopTaskExecutionResult(
            taskId: task.id,
            status: WorkshopTaskStatus.failed,
            message: 'AIrLab proposed file operations but no controlled staging materializer is configured.',
            metadata: <String, dynamic>{
              'executor': executorId,
              'requestId': response.requestId,
              'engineId': response.engineId,
              'code': 'staging_materializer_unavailable',
            },
          );
        }

        final stagingRoot = context.stagingRoot?.trim();
        if (stagingRoot == null || stagingRoot.isEmpty) {
          return WorkshopTaskExecutionResult(
            taskId: task.id,
            status: WorkshopTaskStatus.failed,
            message: 'AIrLab proposed file operations but Cantiere did not assign a staging root.',
            metadata: <String, dynamic>{
              'executor': executorId,
              'requestId': response.requestId,
              'engineId': response.engineId,
              'code': 'staging_root_missing',
            },
          );
        }

        onProgress?.call(
          WorkshopTaskExecutionProgress(
            taskId: task.id,
            phase: 'airlab_stage',
            message: 'Validating AIrLab operations in controlled Cantiere staging.',
          ),
        );

        stagingResult = await materializer.materialize(
          stagingRoot: stagingRoot,
          operations: response.operations,
          fileScope: task.fileScope,
        );

        checkpoint = WorkshopTaskCheckpoint(
          id: '${task.id}-airlab-${response.requestId}',
          createdAt: DateTime.now().toUtc(),
          phase: 'airlab-staged-awaiting-approval',
          completedSteps: const <String>[
            'guard-approved',
            'airlab-round-trip-complete',
            'airlab-operations-validated',
            'airlab-staging-complete',
          ],
          changedFiles: stagingResult.changedFiles,
          metadata: <String, dynamic>{
            'request_id': response.requestId,
            'engine_id': response.engineId,
            'task_id': task.id,
            'stagingOnly': true,
            'repositoryModified': false,
            'operationCount': stagingResult.operationCount,
            'payloadBytes': stagingResult.totalPayloadBytes,
          },
        );

        onProgress?.call(
          WorkshopTaskExecutionProgress(
            taskId: task.id,
            phase: 'airlab_staged',
            message: 'AIrLab operations are staged and require the normal Cantiere approval boundary.',
            completedSteps: stagingResult.operationCount,
            totalSteps: stagingResult.operationCount,
            progress: 1,
            checkpoint: checkpoint,
            metadata: <String, dynamic>{
              'changedFiles': stagingResult.changedFiles,
              'repositoryModified': false,
            },
          ),
        );
      } else {
        onProgress?.call(
          WorkshopTaskExecutionProgress(
            taskId: task.id,
            phase: 'airlab_complete',
            message: 'AIrLab round trip completed.',
            completedSteps: response.plan.length,
            totalSteps: response.plan.length,
            progress: 1,
          ),
        );
      }

      final staged = stagingResult != null;
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: staged
            ? WorkshopTaskStatus.waitingApproval
            : WorkshopTaskStatus.completed,
        message: staged
            ? 'AIrLab output was materialized into controlled staging and is awaiting normal Cantiere approval.'
            : 'AIrLab completed the task round trip.',
        checkpoint: checkpoint,
        changedFiles: stagingResult?.changedFiles ?? const <String>[],
        artifacts: response.artifacts.map((artifact) => artifact.path).toList(growable: false),
        metadata: <String, dynamic>{
          'executor': executorId,
          'requestId': response.requestId,
          'engineId': response.engineId,
          'taskFamily': request.taskFamily,
          'taskKind': request.taskKind,
          'plan': response.plan,
          'artifactFormats': response.artifacts
              .map((artifact) => artifact.format)
              .toList(growable: false),
          'repositoryModified': false,
          'stagingOnly': staged,
          'promotionRequired': staged,
          if (stagingResult != null) ...<String, dynamic>{
            'operationCount': stagingResult.operationCount,
            'createdCount': stagingResult.createdCount,
            'updatedCount': stagingResult.updatedCount,
            'deletedCount': stagingResult.deletedCount,
            'payloadBytes': stagingResult.totalPayloadBytes,
          },
        },
      );
    } on WorkshopAirLabStagingException catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab staging rejected: ${error.message}',
        metadata: <String, dynamic>{
          'executor': executorId,
          'code': error.code,
          if (error.path != null) 'path': error.path,
          'repositoryModified': false,
        },
      );
    } on WorkshopAirLabException catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab request failed: ${error.message}',
        metadata: <String, dynamic>{
          'executor': executorId,
          if (error.statusCode != null) 'statusCode': error.statusCode,
          if (error.code != null) 'code': error.code,
        },
      );
    } on FormatException catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab contract is invalid: ${error.message}',
        metadata: <String, dynamic>{'executor': executorId},
      );
    } on ArgumentError catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab task mapping failed: ${error.message}',
        metadata: <String, dynamic>{'executor': executorId},
      );
    }
  }

  WorkshopTaskExecutionResult? _validateGuard(
    WorkshopTaskContract task,
    WorkshopTaskExecutionGuardDecision decision,
  ) {
    if (!decision.isAllowed) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'Execution rejected by the Workshop Execution Guard: ${decision.message}',
      );
    }
    if (decision.taskId != task.id) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab refused a guard decision for a different task.',
      );
    }
    if (decision.resource != null && decision.resource != resource) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab refused a guard decision for a different resource.',
      );
    }
    if (decision.providerId != null && decision.providerId != providerId) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message: 'AIrLab refused a guard decision for a different provider.',
      );
    }
    return null;
  }

  String? _validateCapabilities(
    WorkshopAirLabCapabilities capabilities,
    WorkshopAirLabTaskRequest request,
  ) {
    if (!capabilities.taskFamilies.contains(request.taskFamily)) {
      return 'AIrLab engine ${capabilities.engineId} does not support ${request.taskFamily} tasks.';
    }
    for (final input in request.inputs) {
      if (!capabilities.inputKinds.contains(input.kind)) {
        return 'AIrLab engine ${capabilities.engineId} does not support input kind ${input.kind}.';
      }
    }
    for (final format in request.requestedArtifacts) {
      if (!capabilities.artifactFormats.contains(format)) {
        return 'AIrLab engine ${capabilities.engineId} does not support artifact format $format.';
      }
    }
    return null;
  }
}
