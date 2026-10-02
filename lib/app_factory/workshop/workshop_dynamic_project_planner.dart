import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';

final class WorkshopDynamicProjectPlan {
  const WorkshopDynamicProjectPlan({
    required this.phases,
    required this.tasks,
  });

  final List<WorkshopProjectPhase> phases;
  final List<WorkshopProjectTask> tasks;
}

/// Cantiere-owned initial project planner.
///
/// Model output is never executable by itself. The pure decoder validates the
/// complete graph before the caller may register a project or open a workspace.
final class WorkshopDynamicProjectPlanner {
  WorkshopDynamicProjectPlanner({
    required WorkshopStageRoleInference inference,
    WorkshopDynamicProjectPlanDecoder decoder =
        const WorkshopDynamicProjectPlanDecoder(),
  })  : _inference = inference,
        _decoder = decoder;

  static const int _primaryMaxTokens = 768;
  static const int _retryMaxTokens = 512;

  final WorkshopStageRoleInference _inference;
  final WorkshopDynamicProjectPlanDecoder _decoder;

  Future<WorkshopDynamicProjectPlan> plan({
    required WorkshopRequest request,
    List<String> requirements = const <String>[],
    List<String> technologies = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final first = await _inference.complete(
      stage: WorkshopStage.planning,
      prompt: _prompt(
        request,
        requirements: requirements,
        technologies: technologies,
        deliverables: deliverables,
        validationCriteria: validationCriteria,
        compact: false,
      ),
      systemPrompt: _systemPrompt,
      sessionId: 'workshop:${request.id}:project-plan',
      isOffline: isOffline,
      maxTokens: _primaryMaxTokens,
      temperature: 0.2,
      cancellationToken: cancellationToken,
    );

    if (!first.isSuccessful || !first.hasText) {
      if (!_shouldRetryPlanning(
        first,
        cancellationToken: cancellationToken,
      )) {
        throw _planningFailure(
          'Cantiere project planning did not complete successfully',
          first,
        );
      }

      return _retryPlan(
        request: request,
        requirements: requirements,
        technologies: technologies,
        deliverables: deliverables,
        validationCriteria: validationCriteria,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }

    try {
      return _decodeForRequest(first.text, request: request);
    } on FormatException {
      if (cancellationToken?.isCancelled == true) rethrow;

      return _retryPlan(
        request: request,
        requirements: requirements,
        technologies: technologies,
        deliverables: deliverables,
        validationCriteria: validationCriteria,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }
  }

  Future<WorkshopDynamicProjectPlan> _retryPlan({
    required WorkshopRequest request,
    required List<String> requirements,
    required List<String> technologies,
    required List<String> deliverables,
    required List<String> validationCriteria,
    required bool isOffline,
    required CancellationToken? cancellationToken,
  }) async {
    final retry = await _inference.complete(
      stage: WorkshopStage.planning,
      prompt: _prompt(
        request,
        requirements: requirements,
        technologies: technologies,
        deliverables: deliverables,
        validationCriteria: validationCriteria,
        compact: true,
      ),
      systemPrompt: _retrySystemPrompt,
      sessionId: 'workshop:${request.id}:project-plan:retry-1',
      isOffline: isOffline,
      maxTokens: _retryMaxTokens,
      temperature: 0.1,
      cancellationToken: cancellationToken,
    );

    if (!retry.isSuccessful || !retry.hasText) {
      throw _planningFailure(
        'Cantiere project planning retry did not complete successfully',
        retry,
      );
    }

    return _decodeForRequest(retry.text, request: request);
  }

  static bool _shouldRetryPlanning(
    WorkshopInferenceResult result, {
    required CancellationToken? cancellationToken,
  }) {
    if (cancellationToken?.isCancelled == true ||
        result.terminalState == InferenceTerminalState.cancelled ||
        result.terminalState == InferenceTerminalState.modelUnavailable) {
      return false;
    }

    return true;
  }

  static StateError _planningFailure(
    String message,
    WorkshopInferenceResult result,
  ) {
    final terminal = result.terminalState?.name ?? 'none';
    final detail = result.errorMessage?.trim();
    return StateError(
      detail == null || detail.isEmpty
          ? '$message (terminal=$terminal).'
          : '$message (terminal=$terminal): $detail',
    );
  }

  WorkshopDynamicProjectPlan _decodeForRequest(
    String raw, {
    required WorkshopRequest request,
  }) {
    final plan = _decoder.decode(raw, requestId: request.id);
    return _enforceRequestInvariants(plan, request);
  }

  static WorkshopDynamicProjectPlan _enforceRequestInvariants(
    WorkshopDynamicProjectPlan plan,
    WorkshopRequest request,
  ) {
    if (request.operation != WorkshopOperation.create || plan.tasks.isEmpty) {
      return plan;
    }

    final rootIndex = plan.tasks.indexWhere(
      (task) => task.dependencies.isEmpty,
    );
    if (rootIndex < 0) {
      throw const FormatException(
        'Create project plan has no dependency-free root task.',
      );
    }

    final root = plan.tasks[rootIndex];
    if (root.affectedPaths.contains('lib/main.dart')) {
      return plan;
    }
    if (root.affectedPaths.length >= WorkshopDynamicProjectPlanDecoder.maxPaths) {
      throw const FormatException(
        'Create root task cannot include required lib/main.dart within path bounds.',
      );
    }

    final tasks = List<WorkshopProjectTask>.of(plan.tasks);
    tasks[rootIndex] = root.copyWith(
      affectedPaths: <String>[
        'lib/main.dart',
        ...root.affectedPaths,
      ],
    );

    return WorkshopDynamicProjectPlan(
      phases: plan.phases,
      tasks: List<WorkshopProjectTask>.unmodifiable(tasks),
    );
  }

  static String _prompt(
    WorkshopRequest request, {
    required List<String> requirements,
    required List<String> technologies,
    required List<String> deliverables,
    required List<String> validationCriteria,
    required bool compact,
  }) {
    final buffer = StringBuffer()
      ..writeln('CANTIERE PROJECT PLANNING REQUEST')
      ..writeln('title: ${request.title}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('operation: ${request.operation.name}')
      ..writeln('targetFiles: ${request.targetFiles.join(', ')}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln('requirements: ${requirements.join(' | ')}')
      ..writeln('technologies: ${technologies.join(' | ')}')
      ..writeln('deliverables: ${deliverables.join(' | ')}')
      ..writeln(
        'validationCriteria: ${validationCriteria.join(' | ')}',
      );

    // WorkshopRequest.context can contain model-authored proposal provenance.
    // It remains available to the later preflight, but initial graph planning
    // does not silently promote it into executable task requirements.

    buffer
      ..writeln()
      ..writeln('Return JSON only with this exact top-level shape:')
      ..writeln(
        '{"phases":[{"id":"implementation","title":"...",'
        '"description":"...","dependsOn":[]}],'
        '"tasks":[{"id":"implement","phaseId":"implementation",'
        '"title":"...","description":"...","dependsOn":[],'
        '"affectedPaths":[],"validationCriteria":["..."]}]}',
      )
      ..writeln()
      ..writeln('Rules:');

    if (compact) {
      buffer
        ..writeln(
          '- retry mode: prefer exactly 1 phase and 1 task when that can '
          'represent the requested work',
        )
        ..writeln(
          '- keep titles, descriptions and validation criteria terse so the '
          'complete JSON fits the response budget',
        )
        ..writeln(
          '- output the JSON object only: no preface, suffix, comments, '
          'Markdown or code fences',
        );
    }

    buffer
      ..writeln('- ids are local lowercase slugs: [a-z][a-z0-9_-]*')
      ..writeln('- 1 to 4 phases; 1 to 12 tasks total')
      ..writeln('- dependencies may reference only ids in this JSON')
      ..writeln('- no cycles')
      ..writeln('- every task has at least one validation criterion')
      ..writeln('- paths are relative repository paths only')
      ..writeln(
        '- for Flutter create work, each task affectedPaths must list every '
        'source file that task may create or modify; do not rely on paths '
        'mentioned only in title, description or requirements',
      )
      ..writeln(
        '- for Flutter create work, the implementation task must include '
        'lib/main.dart so the approved source owns the runnable entry point',
      )
      ..writeln(
        '- keep bounded tasks self-contained: if a task may introduce a new '
        'screen/helper file, include that exact repository path in that task '
        'affectedPaths before execution',
      )
      ..writeln(
        '- Flutter widget/unit tests belong under test/, never lib/test/',
      )
      ..writeln(
        '- preserve explicit dependency constraints; if external packages are '
        'forbidden, keep the plan and implementation SDK-only',
      )
      ..writeln('- simple one-step work should stay one task')
      ..writeln('- substantial app work may use multiple ordered tasks')
      ..writeln('- do not add sensors, permissions, cloud or background work unless requested')
      ..writeln('- do not claim files were changed or a build passed');

    return buffer.toString();
  }

  static const String _systemPrompt =
      'You are the Cantiere Architect. Produce only a bounded project-plan JSON '
      'for the explicit Workshop request. Do not use Assistant memory or '
      'conversation state. Do not write files, approve changes, execute tools '
      'or mutate the workspace. Prefer the smallest valid task graph.';

  static const String _retrySystemPrompt =
      'You are the Cantiere Architect repairing malformed project-plan output. '
      'Return strict JSON only, using the supplied schema. Keep the graph small '
      'and do not invent capabilities.';
}

final class WorkshopDynamicProjectPlanDecoder {
  const WorkshopDynamicProjectPlanDecoder();

  static const int maxPhases = 4;
  static const int maxTasks = 12;
  static const int _maxTitleChars = 160;
  static const int _maxDescriptionChars = 800;
  static const int _maxCriteria = 8;
  static const int _maxCriterionChars = 240;
  static const int maxPaths = 16;
  static const int _maxPathChars = 220;
  static final RegExp _localId = RegExp(r'^[a-z][a-z0-9_-]{0,47}$');

  WorkshopDynamicProjectPlan decode(
    String raw, {
    required String requestId,
  }) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(_extractJson(raw));
    } on FormatException {
      throw const FormatException('Project plan is not valid JSON.');
    }

    if (decoded is! Map) {
      throw const FormatException('Project plan root must be an object.');
    }

    final root = Map<String, dynamic>.from(decoded);
    final rawPhases = _list(root['phases'], 'phases');
    final rawTasks = _list(root['tasks'], 'tasks');

    if (rawPhases.isEmpty || rawPhases.length > maxPhases) {
      throw const FormatException('Project plan must contain 1 to 4 phases.');
    }
    if (rawTasks.isEmpty || rawTasks.length > maxTasks) {
      throw const FormatException('Project plan must contain 1 to 12 tasks.');
    }

    final phaseRows =
        rawPhases.map((value) => _map(value, 'phase')).toList(growable: false);
    final taskRows =
        rawTasks.map((value) => _map(value, 'task')).toList(growable: false);

    final phaseIds = <String>{};
    for (final phase in phaseRows) {
      final id = _id(phase['id'], 'phase.id');
      if (!phaseIds.add(id)) {
        throw FormatException('Duplicate phase id: $id');
      }
    }

    final taskIds = <String>{};
    for (final task in taskRows) {
      final id = _id(task['id'], 'task.id');
      if (!taskIds.add(id)) {
        throw FormatException('Duplicate task id: $id');
      }
    }

    final phaseDeps = <String, List<String>>{};
    for (final phase in phaseRows) {
      final id = _id(phase['id'], 'phase.id');
      final dependencies = _ids(phase['dependsOn'], 'phase.dependsOn');
      for (final dependency in dependencies) {
        if (!phaseIds.contains(dependency) || dependency == id) {
          throw FormatException('Invalid phase dependency $dependency for $id.');
        }
      }
      phaseDeps[id] = dependencies;
    }
    _rejectCycles(phaseDeps, 'phase');

    final taskPhaseById = <String, String>{};
    final tasksByPhase = <String, List<String>>{
      for (final phaseId in phaseIds) phaseId: <String>[],
    };
    final explicitTaskDeps = <String, List<String>>{};
    for (final task in taskRows) {
      final id = _id(task['id'], 'task.id');
      final phaseId = _id(task['phaseId'], 'task.phaseId');
      if (!phaseIds.contains(phaseId)) {
        throw FormatException('Task $id references unknown phase $phaseId.');
      }
      taskPhaseById[id] = phaseId;
      tasksByPhase[phaseId]!.add(id);

      final dependencies = _ids(task['dependsOn'], 'task.dependsOn');
      for (final dependency in dependencies) {
        if (!taskIds.contains(dependency) || dependency == id) {
          throw FormatException('Invalid task dependency $dependency for $id.');
        }
      }
      explicitTaskDeps[id] = dependencies;
    }

    // Phase dependencies are execution constraints, not presentation-only
    // metadata. Materialize them into the task graph so nextAvailableTask
    // cannot start work from a dependent phase early.
    final taskDeps = <String, List<String>>{};
    for (final id in taskIds) {
      final phaseId = taskPhaseById[id]!;
      final resolved = <String>{
        ...explicitTaskDeps[id]!,
        for (final dependencyPhase in phaseDeps[phaseId]!)
          ...tasksByPhase[dependencyPhase]!,
      };
      resolved.remove(id);
      taskDeps[id] = resolved.toList(growable: false);
    }
    _rejectCycles(taskDeps, 'task');

    final scope = _scope(requestId);
    final phaseIdMap = <String, String>{
      for (final id in phaseIds) id: 'phase:$scope:$id',
    };
    final taskIdMap = <String, String>{
      for (final id in taskIds) id: 'task:$scope:$id',
    };

    final tasks = <WorkshopProjectTask>[];
    for (final row in taskRows) {
      final rawId = _id(row['id'], 'task.id');
      final rawPhaseId = _id(row['phaseId'], 'task.phaseId');
      tasks.add(
        WorkshopProjectTask(
          id: taskIdMap[rawId]!,
          title: _boundedString(row['title'], 'task.title', _maxTitleChars),
          description: _boundedString(
            row['description'],
            'task.description',
            _maxDescriptionChars,
          ),
          phaseId: phaseIdMap[rawPhaseId]!,
          dependencies: taskDeps[rawId]!
              .map((id) => taskIdMap[id]!)
              .toList(growable: false),
          affectedPaths: _paths(row['affectedPaths']),
          validationCriteria: _boundedStrings(
            row['validationCriteria'],
            'task.validationCriteria',
            maxItems: _maxCriteria,
            maxChars: _maxCriterionChars,
            requireNonEmpty: true,
          ),
        ),
      );
    }

    final phases = <WorkshopProjectPhase>[];
    for (final row in phaseRows) {
      final rawId = _id(row['id'], 'phase.id');
      final resolvedPhaseId = phaseIdMap[rawId]!;
      final phaseTasks = tasks
          .where((task) => task.phaseId == resolvedPhaseId)
          .toList(growable: false);
      if (phaseTasks.isEmpty) {
        throw FormatException('Phase $rawId contains no task.');
      }
      phases.add(
        WorkshopProjectPhase(
          id: resolvedPhaseId,
          title: _boundedString(row['title'], 'phase.title', _maxTitleChars),
          description: _boundedString(
            row['description'],
            'phase.description',
            _maxDescriptionChars,
          ),
          dependencies: phaseDeps[rawId]!
              .map((id) => phaseIdMap[id]!)
              .toList(growable: false),
          taskIds: phaseTasks.map((task) => task.id).toList(growable: false),
          validationCriteria: phaseTasks
              .expand((task) => task.validationCriteria)
              .take(_maxCriteria)
              .toList(growable: false),
        ),
      );
    }

    return WorkshopDynamicProjectPlan(
      phases: List<WorkshopProjectPhase>.unmodifiable(phases),
      tasks: List<WorkshopProjectTask>.unmodifiable(tasks),
    );
  }

  static String _extractJson(String raw) {
    var value = raw.trim();
    final fence = String.fromCharCodes(const <int>[96, 96, 96]);
    if (value.startsWith(fence)) {
      final firstNewline = value.indexOf('\n');
      final lastFence = value.lastIndexOf(fence);
      if (firstNewline >= 0 && lastFence > firstNewline) {
        value = value.substring(firstNewline + 1, lastFence).trim();
      }
    }

    // Preserve strict validation for already-valid JSON roots. Recovery is only
    // used when the model wrapped an otherwise complete project object in brief
    // prose or another non-JSON envelope.
    try {
      jsonDecode(value);
      return value;
    } on FormatException {
      return _firstProjectJsonObject(value) ?? value;
    }
  }

  static String? _firstProjectJsonObject(String value) {
    final starts = <int>[];
    var inString = false;
    var escaped = false;

    for (var index = 0; index < value.length; index += 1) {
      final codeUnit = value.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (codeUnit == 0x5c) {
          escaped = true;
        } else if (codeUnit == 0x22) {
          inString = false;
        }
        continue;
      }
      if (codeUnit == 0x22) {
        inString = true;
      } else if (codeUnit == 0x7b) {
        starts.add(index);
      }
    }

    for (final start in starts) {
      final candidate = _balancedObjectFrom(value, start);
      if (candidate == null) {
        continue;
      }
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map &&
            decoded.containsKey('phases') &&
            decoded.containsKey('tasks')) {
          return candidate;
        }
      } on FormatException {
        // Try the next object start. Nested complete project objects remain
        // recoverable even when an outer wrapper was truncated.
      }
    }

    return null;
  }

  static String? _balancedObjectFrom(String value, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var index = start; index < value.length; index += 1) {
      final codeUnit = value.codeUnitAt(index);

      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (codeUnit == 0x5c) {
          escaped = true;
        } else if (codeUnit == 0x22) {
          inString = false;
        }
        continue;
      }

      if (codeUnit == 0x22) {
        inString = true;
        continue;
      }
      if (codeUnit == 0x7b) {
        depth += 1;
        continue;
      }
      if (codeUnit != 0x7d || depth == 0) {
        continue;
      }

      depth -= 1;
      if (depth == 0) {
        return value.substring(start, index + 1);
      }
    }

    return null;
  }

  static List<dynamic> _list(Object? value, String field) {
    if (value is! List) {
      throw FormatException('$field must be a list.');
    }
    return value;
  }

  static Map<String, dynamic> _map(Object? value, String field) {
    if (value is! Map) {
      throw FormatException('$field must be an object.');
    }
    return Map<String, dynamic>.from(value);
  }

  static String _id(Object? value, String field) {
    if (value is! String || !_localId.hasMatch(value.trim())) {
      throw FormatException('$field is invalid.');
    }
    return value.trim();
  }

  static List<String> _ids(Object? value, String field) {
    if (value == null) return const <String>[];
    if (value is! List || value.length > maxTasks) {
      throw FormatException('$field must be a bounded list.');
    }
    return value.map((item) => _id(item, field)).toList(growable: false);
  }

  static String _boundedString(Object? value, String field, int maxChars) {
    if (value is! String) {
      throw FormatException('$field must be a string.');
    }
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maxChars) {
      throw FormatException('$field is empty or too long.');
    }
    return normalized;
  }

  static List<String> _boundedStrings(
    Object? value,
    String field, {
    required int maxItems,
    required int maxChars,
    bool requireNonEmpty = false,
  }) {
    if (value is! List || value.length > maxItems) {
      throw FormatException('$field must be a bounded list.');
    }
    final result = value
        .map((item) => _boundedString(item, field, maxChars))
        .toList(growable: false);
    if (requireNonEmpty && result.isEmpty) {
      throw FormatException('$field cannot be empty.');
    }
    return result;
  }

  static List<String> _paths(Object? value) {
    if (value == null) return const <String>[];
    final paths = _boundedStrings(
      value,
      'task.affectedPaths',
      maxItems: maxPaths,
      maxChars: _maxPathChars,
    );
    for (final path in paths) {
      final segments = path.split('/');
      if (path.startsWith('/') ||
          path.startsWith('\\') ||
          path.contains('\\') ||
          path.contains(':') ||
          segments.any(
            (segment) =>
                segment.isEmpty ||
                segment == '..' ||
                segment == '.' ||
                segment == '~',
          )) {
        throw FormatException('Unsafe affected path: $path');
      }
    }
    return paths;
  }

  static void _rejectCycles(Map<String, List<String>> graph, String kind) {
    final visiting = <String>{};
    final visited = <String>{};

    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) {
        throw FormatException('$kind dependency graph contains a cycle at $id.');
      }
      for (final dependency in graph[id] ?? const <String>[]) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
    }

    for (final id in graph.keys) {
      visit(id);
    }
  }

  static String _scope(String requestId) {
    var value = requestId
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (value.isEmpty) value = 'project';
    if (value.length > 32) value = value.substring(value.length - 32);
    return value;
  }
}
