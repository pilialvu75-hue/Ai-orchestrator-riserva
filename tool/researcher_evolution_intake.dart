import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_task_projection.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_research_evolution_bridge.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/researcher_evolution_intake.dart '
      '<payload.json> <output-dir>',
    );
    exitCode = 64;
    return;
  }

  final input = File(args[0]);
  final output = Directory(args[1]);

  if (!await input.exists()) {
    stderr.writeln('Researcher evolution payload does not exist.');
    exitCode = 66;
    return;
  }

  final decoded = jsonDecode(await input.readAsString());
  if (decoded is! Map) {
    stderr.writeln('Researcher evolution payload must be a JSON object.');
    exitCode = 65;
    return;
  }

  final payload = Map<String, dynamic>.from(decoded);
  final request = WorkshopResearchEvolutionRequest.fromJson(payload);
  request.validate();

  final task =
      const WorkshopResearchEvolutionTaskAdapter().toTask(request);
  final project =
      const WorkshopResearchEvolutionProjectAdapter().toProject(task);

  // Durable scheduling starts only after the exact Cantiere contract has
  // passed the Researcher isolation boundary.
  task.markReady();
  final observedAt = DateTime.now().toUtc();
  final durableTask = WorkshopDurableTaskProjection.fromContract(
    task,
    capabilityResolver: (_) => 'coding.module_evolution',
    observedAt: observedAt,
  );
  final durableProject = WorkshopDurableProjectSnapshot(
    projectId: project.id,
    correlationId: 'researcher-evolution:${request.proposalId}',
    state: WorkshopDurableState.ready,
    createdAt: observedAt,
    updatedAt: observedAt,
    tasks: <String, WorkshopDurableTask>{
      durableTask.taskId: durableTask,
    },
  );

  await output.create(recursive: true);

  final normalizedPayload = <String, Object?>{
    'schema': 'ai-orchestrator.researcher-evolution-intake.v1',
    'proposal_id': request.proposalId,
    'capability_id': request.capabilityId,
    'knowledge_delta': request.knowledgeDelta,
    'acceptance_gates': request.acceptanceGates,
    'mutation_policy': request.mutationPolicy,
    'source_code_transferred': false,
  };

  await _writeJson(
    File('${output.path}/researcher-evolution-work.json'),
    normalizedPayload,
  );
  await _writeJson(
    File('${output.path}/workshop-task-contract.json'),
    task.toJson(),
  );
  await _writeJson(
    File('${output.path}/workshop-durable-project.json'),
    durableProject.toJson(),
  );

  stdout.writeln(
    '[RESEARCHER_EVOLUTION_INTAKE] '
    'proposal_id=${request.proposalId} '
    'task_id=${task.id} '
    'project_id=${project.id} '
    'durable_state=${durableProject.state.name}',
  );
}

Future<void> _writeJson(File file, Object? value) {
  const encoder = JsonEncoder.withIndent('  ');
  return file.writeAsString('${encoder.convert(value)}\n');
}
