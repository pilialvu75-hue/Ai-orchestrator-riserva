import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_read_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

final class WorkshopLibraryApprovedHandoffException implements Exception {
  const WorkshopLibraryApprovedHandoffException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() =>
      'WorkshopLibraryApprovedHandoffException($code): $message';
}

final class WorkshopLibraryApprovedHandoffRequest {
  const WorkshopLibraryApprovedHandoffRequest({
    required this.taskId,
    required this.title,
    required this.objective,
    required this.pin,
    required this.capabilityId,
    required this.contractId,
    required this.targets,
    required this.authorizedFileScope,
    this.mode = WorkshopTaskMode.hybrid,
    this.preferredResource = WorkshopTaskResource.local,
    this.fallbackResources = const <WorkshopTaskResource>[
      WorkshopTaskResource.hybridAi,
      WorkshopTaskResource.githubActions,
    ],
    this.priority = WorkshopTaskPriority.normal,
    this.budget = const WorkshopTaskBudget(),
  });

  final String taskId;
  final String title;
  final String objective;
  final String pin;
  final String capabilityId;
  final String contractId;
  final List<String> targets;

  /// Scope already authorized by the owning Cantiere project/request.
  /// Library certification must never widen this boundary.
  final WorkshopTaskFileScope authorizedFileScope;

  final WorkshopTaskMode mode;
  final WorkshopTaskResource preferredResource;
  final List<WorkshopTaskResource> fallbackResources;
  final WorkshopTaskPriority priority;
  final WorkshopTaskBudget budget;
}

final class WorkshopLibraryApprovedHandoffProof {
  const WorkshopLibraryApprovedHandoffProof({
    required this.libraryId,
    required this.catalogVersion,
    required this.snapshotSha256,
    required this.pin,
    required this.manifestSha256,
    required this.moduleTreeSha256,
    required this.packageSha256,
    required this.capabilityId,
    required this.contractId,
    required this.targets,
    required this.validationScore,
  });

  final String libraryId;
  final String catalogVersion;
  final String snapshotSha256;
  final String pin;
  final String manifestSha256;
  final String moduleTreeSha256;
  final String packageSha256;
  final String capabilityId;
  final String contractId;
  final List<String> targets;
  final double validationScore;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': 'ai-orchestrator.library-approved-handoff-proof.v1',
        'libraryId': libraryId,
        'catalogVersion': catalogVersion,
        'snapshotSha256': snapshotSha256,
        'pin': pin,
        'manifestSha256': manifestSha256,
        'moduleTreeSha256': moduleTreeSha256,
        'packageSha256': packageSha256,
        'capabilityId': capabilityId,
        'contractId': contractId,
        'targets': targets,
        'validationScore': validationScore,
      };
}

final class WorkshopLibraryApprovedHandoff {
  const WorkshopLibraryApprovedHandoff({
    required this.task,
    required this.proof,
  });

  final WorkshopTaskContract task;
  final WorkshopLibraryApprovedHandoffProof proof;
}

/// Fail-closed Library -> Cantiere handoff.
///
/// Researcher is deliberately absent from this API. The only accepted
/// authority is the canonical Module Library read client:
///
/// verified Library snapshot
///   -> exact certified/active asset pin
///   -> exact verified package envelope
///   -> project-bounded WorkshopTaskContract
///
/// The returned task remains PLANNED. Library certification proves that the
/// reusable asset is eligible to be considered; it does not grant project
/// authorization, Reviewer approval, validation approval or real-workspace
/// apply authority.
final class WorkshopLibraryApprovedHandoffService {
  const WorkshopLibraryApprovedHandoffService({
    required this.client,
    this.minimumValidationScore = 0.8,
  }) : assert(
          minimumValidationScore >= 0 && minimumValidationScore <= 1,
        );

  static const String canonicalLibraryId =
      'ai-orchestrator-module-library';
  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  final WorkshopLibraryReadClient client;
  final double minimumValidationScore;

  Future<WorkshopLibraryApprovedHandoff> prepare(
    WorkshopLibraryApprovedHandoffRequest request,
  ) async {
    final taskId = _required(request.taskId, 'task_id_missing');
    final title = _required(request.title, 'title_missing');
    final objective = _required(request.objective, 'objective_missing');
    final pin = _required(request.pin, 'pin_missing');
    final capabilityId =
        _required(request.capabilityId, 'capability_missing');
    final contractId = _required(request.contractId, 'contract_missing');
    final targets = _uniqueNonEmpty(request.targets);
    if (targets.isEmpty) {
      throw const WorkshopLibraryApprovedHandoffException(
        'targets_missing',
        'Library-approved handoff requires at least one explicit target.',
      );
    }

    final scope = _validatedScope(request.authorizedFileScope);

    final state = await client.loadState();
    if (state.snapshot.libraryId != canonicalLibraryId) {
      throw const WorkshopLibraryApprovedHandoffException(
        'library_authority_invalid',
        'Handoff must originate from the canonical Module Library.',
      );
    }

    final asset = state.snapshot.assetByPin(pin);
    if (asset == null) {
      throw const WorkshopLibraryApprovedHandoffException(
        'pin_not_certified',
        'Requested pin is absent from the verified certified snapshot.',
      );
    }

    final candidate = asset.candidate;
    if (candidate.availability !=
        WorkshopLibraryCandidateAvailability.active) {
      throw const WorkshopLibraryApprovedHandoffException(
        'asset_not_active',
        'Only active certified Library assets can create an executable handoff.',
      );
    }
    if (candidate.validationScore < minimumValidationScore) {
      throw const WorkshopLibraryApprovedHandoffException(
        'validation_below_policy',
        'Certified asset validation score is below Cantiere policy.',
      );
    }
    if (!candidate.capabilities.contains(capabilityId)) {
      throw const WorkshopLibraryApprovedHandoffException(
        'capability_mismatch',
        'Certified asset does not provide the requested capability.',
      );
    }
    if (!candidate.contracts.contains(contractId)) {
      throw const WorkshopLibraryApprovedHandoffException(
        'contract_mismatch',
        'Certified asset does not implement the requested contract.',
      );
    }
    if (!candidate.targets.toSet().containsAll(targets)) {
      throw const WorkshopLibraryApprovedHandoffException(
        'target_mismatch',
        'Certified asset was not validated for every requested target.',
      );
    }

    final indexEntry = state.packageIndex[pin];
    if (indexEntry == null ||
        indexEntry.pin != pin ||
        indexEntry.moduleTreeSha256 != asset.moduleTreeSha256 ||
        !_sha256.hasMatch(indexEntry.packageSha256)) {
      throw const WorkshopLibraryApprovedHandoffException(
        'package_index_unverified',
        'Verified Library snapshot and package index are not consistent.',
      );
    }

    late final WorkshopReusableModulePackage package;
    try {
      package = await client.loadPackage(state: state, pin: pin);
    } catch (_) {
      throw const WorkshopLibraryApprovedHandoffException(
        'package_unverified',
        'Exact Library package envelope could not be verified.',
      );
    }

    if (package.pin != pin ||
        package.availability != WorkshopLibraryCandidateAvailability.active ||
        package.manifestDigest != asset.manifestSha256 ||
        package.artifactDigest != asset.moduleTreeSha256 ||
        !_sameSet(package.capabilities, candidate.capabilities) ||
        !_sameSet(package.contracts, candidate.contracts) ||
        !package.capabilities.contains(capabilityId) ||
        !package.contracts.contains(contractId)) {
      throw const WorkshopLibraryApprovedHandoffException(
        'package_snapshot_mismatch',
        'Verified package does not match the selected certified snapshot asset.',
      );
    }

    final allowed = scope.allowed.toSet();
    for (final file in package.files) {
      if (!allowed.contains(file.targetPath)) {
        throw WorkshopLibraryApprovedHandoffException(
          'package_scope_violation',
          'Certified package target is outside project-authorized scope: '
              + file.targetPath,
        );
      }
    }

    final proof = WorkshopLibraryApprovedHandoffProof(
      libraryId: state.snapshot.libraryId,
      catalogVersion: state.snapshot.catalogVersion,
      snapshotSha256: state.snapshot.snapshotSha256,
      pin: pin,
      manifestSha256: asset.manifestSha256,
      moduleTreeSha256: asset.moduleTreeSha256,
      packageSha256: indexEntry.packageSha256,
      capabilityId: capabilityId,
      contractId: contractId,
      targets: List<String>.unmodifiable(targets),
      validationScore: candidate.validationScore,
    );

    final requirementMetadata = package.requirements
        .map((item) => item.toJson())
        .toList(growable: false);
    final requiredRequirements = package.requirements
        .where((item) => item.required)
        .map((item) => '[${item.kind.name}] ${item.description}')
        .toList(growable: false);

    final task = WorkshopTaskContract(
      id: taskId,
      title: title,
      objective: objective,
      kind: WorkshopTaskKind.integration,
      mode: request.mode,
      preferredResource: request.preferredResource,
      fallbackResources:
          List<WorkshopTaskResource>.unmodifiable(request.fallbackResources),
      priority: request.priority,
      status: WorkshopTaskStatus.planned,
      instructions: List<String>.unmodifiable(<String>[
        'Integrate only the exact certified Library pin $pin.',
        'Preserve capability $capabilityId and contract $contractId.',
        'Re-verify the Library handoff proof before consuming package content.',
        ...requiredRequirements,
      ]),
      constraints: const <String>[
        'Do not widen the project-authorized file scope.',
        'Do not substitute another Library asset or version.',
        'Do not mutate the Module Library from this task.',
        'Do not consume raw Researcher output or repository_dispatch payloads.',
        'Do not bypass Reviewer, validation, owner approval, or guarded apply.',
      ],
      acceptanceCriteria: const <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'library_handoff_integrity_verified',
          description:
              'Library snapshot, manifest, module tree and package digests remain bound to the approved pin.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'integration_requirements_satisfied',
          description:
              'All required package integration requirements are satisfied or the task stops fail-closed.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'reviewer_approved',
          description:
              'Cantiere Reviewer approves the resulting VirtualWorkspace changes.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'validation_passed',
          description:
              'Cantiere validation passes for the project target before apply.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'owner_apply_boundary_preserved',
          description:
              'No real-workspace apply occurs without the normal owner/project authorization boundary.',
        ),
      ],
      fileScope: scope,
      budget: request.budget,
      requiredCheckpoints: const <String>[
        'library_handoff_verified',
        'candidate_created',
        'review_completed',
        'validation_completed',
      ],
      tags: <String>[
        'library-approved',
        'durable-handoff',
        capabilityId,
      ],
      metadata: <String, dynamic>{
        'libraryApprovedHandoff': true,
        'requiresProjectAuthorization': true,
        'durableCapability': 'codeGeneration',
        'libraryProof': proof.toJson(),
        'libraryRequirements': requirementMetadata,
      },
    );

    return WorkshopLibraryApprovedHandoff(task: task, proof: proof);
  }

  WorkshopTaskFileScope _validatedScope(WorkshopTaskFileScope raw) {
    final allowed = _uniqueNonEmpty(raw.allowed);
    final forbidden = _uniqueNonEmpty(raw.forbidden);
    final readOnly = _uniqueNonEmpty(raw.readOnly);
    if (allowed.isEmpty) {
      throw const WorkshopLibraryApprovedHandoffException(
        'authorized_scope_missing',
        'Library-approved work requires an explicit project-authorized file scope.',
      );
    }

    final conflicts = allowed.toSet()
      ..retainAll(<String>{...forbidden, ...readOnly});
    if (conflicts.isNotEmpty) {
      throw const WorkshopLibraryApprovedHandoffException(
        'authorized_scope_conflict',
        'Writable Library handoff scope overlaps forbidden/read-only scope.',
      );
    }

    return WorkshopTaskFileScope(
      allowed: List<String>.unmodifiable(allowed),
      forbidden: List<String>.unmodifiable(forbidden),
      readOnly: List<String>.unmodifiable(readOnly),
    );
  }

  static String _required(String raw, String code) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw WorkshopLibraryApprovedHandoffException(
        code,
        'Required Library handoff identity is empty.',
      );
    }
    return value;
  }

  static List<String> _uniqueNonEmpty(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      final value = raw.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      result.add(value);
    }
    result.sort();
    return result;
  }

  static bool _sameSet(Iterable<String> left, Iterable<String> right) {
    final a = left.toSet();
    final b = right.toSet();
    return a.length == b.length && a.containsAll(b);
  }
}
