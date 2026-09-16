enum WorkshopAirLabAvailability {
  available,
  unavailable,
  incompatible,
}

class WorkshopAirLabProbe {
  const WorkshopAirLabProbe({
    required this.availability,
    this.engineId,
    this.reason,
  });

  final WorkshopAirLabAvailability availability;
  final String? engineId;
  final String? reason;

  bool get isAvailable => availability == WorkshopAirLabAvailability.available;
}

class WorkshopAirLabCapabilities {
  const WorkshopAirLabCapabilities({
    required this.service,
    required this.engineId,
    required this.engineKind,
    required this.hardwareRequired,
    required this.supportsStreaming,
    required this.supportsTools,
    required this.taskFamilies,
    required this.inputKinds,
    required this.artifactFormats,
    this.maxContextTokens,
  });

  factory WorkshopAirLabCapabilities.fromJson(Map<String, dynamic> json) {
    return WorkshopAirLabCapabilities(
      service: _requiredString(json, 'service'),
      engineId: _requiredString(json, 'engine_id'),
      engineKind: _requiredString(json, 'engine_kind'),
      hardwareRequired: json['hardware_required'] == true,
      supportsStreaming: json['supports_streaming'] == true,
      supportsTools: json['supports_tools'] == true,
      maxContextTokens: json['max_context_tokens'] is int
          ? json['max_context_tokens'] as int
          : null,
      taskFamilies: _stringList(json['task_families'], 'task_families'),
      inputKinds: _stringList(json['input_kinds'], 'input_kinds'),
      artifactFormats: _stringList(json['artifact_formats'], 'artifact_formats'),
    );
  }

  final String service;
  final String engineId;
  final String engineKind;
  final bool hardwareRequired;
  final bool supportsStreaming;
  final bool supportsTools;
  final int? maxContextTokens;
  final List<String> taskFamilies;
  final List<String> inputKinds;
  final List<String> artifactFormats;
}

class WorkshopAirLabTaskInput {
  const WorkshopAirLabTaskInput({
    required this.kind,
    required this.reference,
    this.metadata = const <String, dynamic>{},
  });

  final String kind;
  final String reference;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'reference': reference,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };
}

class WorkshopAirLabTaskRequest {
  const WorkshopAirLabTaskRequest({
    required this.task,
    this.projectId = 'default',
    this.target = 'web',
    this.mode = 'plan',
    this.taskFamily = 'software',
    this.taskKind = 'software.build',
    this.inputs = const <WorkshopAirLabTaskInput>[],
    this.requestedArtifacts = const <String>[],
    this.context = const <String, dynamic>{},
  });

  final String task;
  final String projectId;
  final String target;
  final String mode;
  final String taskFamily;
  final String taskKind;
  final List<WorkshopAirLabTaskInput> inputs;
  final List<String> requestedArtifacts;
  final Map<String, dynamic> context;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'task': task,
        'project_id': projectId,
        'target': target,
        'mode': mode,
        'task_family': taskFamily,
        'task_kind': taskKind,
        if (inputs.isNotEmpty)
          'inputs': inputs.map((input) => input.toJson()).toList(growable: false),
        if (requestedArtifacts.isNotEmpty)
          'requested_artifacts': requestedArtifacts,
        if (context.isNotEmpty) 'context': context,
      };
}

class WorkshopAirLabArtifact {
  const WorkshopAirLabArtifact({
    required this.format,
    required this.role,
    required this.path,
    required this.editable,
    required this.derived,
    required this.status,
  });

  factory WorkshopAirLabArtifact.fromJson(Map<String, dynamic> json) {
    return WorkshopAirLabArtifact(
      format: _requiredString(json, 'format'),
      role: _requiredString(json, 'role'),
      path: _requiredString(json, 'path'),
      editable: json['editable'] == true,
      derived: json['derived'] == true,
      status: _requiredString(json, 'status'),
    );
  }

  final String format;
  final String role;
  final String path;
  final bool editable;
  final bool derived;
  final String status;
}

enum WorkshopAirLabFileOperationAction {
  create,
  update,
  delete,
}

/// Untrusted file operation proposed by AIrLab.
///
/// Parsing this contract never grants write authority. Cantiere must validate
/// paths, file scope, payload limits and staging containment before applying it.
final class WorkshopAirLabFileOperation {
  const WorkshopAirLabFileOperation({
    required this.action,
    required this.path,
    this.content,
  });

  factory WorkshopAirLabFileOperation.fromJson(Map<String, dynamic> json) {
    final rawAction = _requiredString(json, 'action').trim().toLowerCase();
    final action = switch (rawAction) {
      'create' => WorkshopAirLabFileOperationAction.create,
      'update' => WorkshopAirLabFileOperationAction.update,
      'delete' => WorkshopAirLabFileOperationAction.delete,
      _ => throw FormatException(
          'AIrLab operation action "$rawAction" is not supported.',
        ),
    };
    final path = _requiredString(json, 'path');
    final rawContent = json['content'];
    if (rawContent != null && rawContent is! String) {
      throw const FormatException(
        'AIrLab operation content must be a string when present.',
      );
    }
    if ((action == WorkshopAirLabFileOperationAction.create ||
            action == WorkshopAirLabFileOperationAction.update) &&
        rawContent == null) {
      throw FormatException(
        'AIrLab ${action.name} operation requires content.',
      );
    }
    if (action == WorkshopAirLabFileOperationAction.delete &&
        rawContent != null) {
      throw const FormatException(
        'AIrLab delete operation cannot include content.',
      );
    }

    return WorkshopAirLabFileOperation(
      action: action,
      path: path,
      content: rawContent as String?,
    );
  }

  final WorkshopAirLabFileOperationAction action;
  final String path;
  final String? content;
}

class WorkshopAirLabTaskResponse {
  const WorkshopAirLabTaskResponse({
    required this.requestId,
    required this.status,
    required this.engineId,
    required this.plan,
    required this.artifacts,
    required this.metadata,
    this.operations = const <WorkshopAirLabFileOperation>[],
  });

  factory WorkshopAirLabTaskResponse.fromJson(Map<String, dynamic> json) {
    final rawArtifacts = json['artifacts'];
    if (rawArtifacts is! List) {
      throw const FormatException('AIrLab artifacts must be an array.');
    }
    final metadata = json['metadata'];
    if (metadata is! Map) {
      throw const FormatException('AIrLab metadata must be an object.');
    }

    final artifacts = <WorkshopAirLabArtifact>[];
    for (final artifact in rawArtifacts) {
      if (artifact is! Map) {
        throw const FormatException('Each AIrLab artifact must be an object.');
      }
      artifacts.add(
        WorkshopAirLabArtifact.fromJson(
          Map<String, dynamic>.from(artifact),
        ),
      );
    }

    final operations = <WorkshopAirLabFileOperation>[];
    final rawOperations = json['operations'];
    if (rawOperations != null) {
      if (rawOperations is! List) {
        throw const FormatException('AIrLab operations must be an array.');
      }
      for (final operation in rawOperations) {
        if (operation is! Map) {
          throw const FormatException('Each AIrLab operation must be an object.');
        }
        operations.add(
          WorkshopAirLabFileOperation.fromJson(
            Map<String, dynamic>.from(operation),
          ),
        );
      }
    }

    return WorkshopAirLabTaskResponse(
      requestId: _requiredString(json, 'request_id'),
      status: _requiredString(json, 'status'),
      engineId: _requiredString(json, 'engine_id'),
      plan: _stringList(json['plan'], 'plan'),
      operations: List<WorkshopAirLabFileOperation>.unmodifiable(operations),
      artifacts: List<WorkshopAirLabArtifact>.unmodifiable(artifacts),
      metadata: Map<String, dynamic>.from(metadata),
    );
  }

  final String requestId;
  final String status;
  final String engineId;
  final List<String> plan;
  final List<WorkshopAirLabFileOperation> operations;
  final List<WorkshopAirLabArtifact> artifacts;
  final Map<String, dynamic> metadata;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('AIrLab field "$key" must be a non-empty string.');
  }
  return value;
}

List<String> _stringList(Object? value, String field) {
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('AIrLab field "$field" must be an array of strings.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}
