import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_task_projection.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_approved_handoff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_read_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_remote_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pin = 'demo.asset@1.0.0';
  final manifestSha = List<String>.filled(64, 'a').join();
  final treeSha = List<String>.filled(64, 'b').join();
  final packageSha = List<String>.filled(64, 'c').join();
  final snapshotSha = List<String>.filled(64, 'd').join();

  WorkshopLibraryRemoteState state({
    WorkshopLibraryCandidateAvailability availability =
        WorkshopLibraryCandidateAvailability.active,
    List<String> capabilities = const <String>['demo.capability'],
    List<String> contracts = const <String>['demo.capability.v1'],
    List<String> targets = const <String>['android'],
    double validationScore = 1,
  }) {
    final candidate = WorkshopLibraryCandidate(
      assetId: 'demo.asset',
      version: '1.0.0',
      capabilities: capabilities,
      contracts: contracts,
      targets: targets,
      availability: availability,
      validationScore: validationScore,
      resolutionScore: 0.9,
      integrationEffort: WorkshopLibraryIntegrationEffort.low,
    );
    return WorkshopLibraryRemoteState(
      snapshot: WorkshopLibrarySnapshot(
        libraryId: WorkshopLibraryApprovedHandoffService.canonicalLibraryId,
        catalogVersion: '1.2.3',
        snapshotSha256: snapshotSha,
        assets: <WorkshopLibrarySnapshotAsset>[
          WorkshopLibrarySnapshotAsset(
            candidate: candidate,
            manifestSha256: manifestSha,
            moduleTreeSha256: treeSha,
          ),
        ],
      ),
      packageIndex: <String, WorkshopLibraryPackageIndexEntry>{
        pin: WorkshopLibraryPackageIndexEntry(
          pin: pin,
          path: 'packages/demo.asset/1.0.0/package.json',
          packageSha256: packageSha,
          moduleTreeSha256: treeSha,
        ),
      },
    );
  }

  WorkshopReusableModulePackage package({
    WorkshopLibraryCandidateAvailability availability =
        WorkshopLibraryCandidateAvailability.active,
    String? packageManifestSha,
    String? packageTreeSha,
    List<String> capabilities = const <String>['demo.capability'],
    List<String> contracts = const <String>['demo.capability.v1'],
    String targetPath = 'lib/demo.dart',
  }) =>
      WorkshopReusableModulePackage(
        assetId: 'demo.asset',
        version: '1.0.0',
        capabilities: capabilities,
        contracts: contracts,
        availability: availability,
        manifestDigest: packageManifestSha ?? manifestSha,
        artifactDigest: packageTreeSha ?? treeSha,
        files: <WorkshopReusableModuleFile>[
          WorkshopReusableModuleFile(
            sourcePath: 'lib/demo.dart',
            targetPath: targetPath,
            content: 'class Demo {}\n',
          ),
        ],
        requirements: const <WorkshopAssemblyRequirement>[
          WorkshopAssemblyRequirement(
            kind: WorkshopAssemblyRequirementKind.manualReview,
            description: 'Revalidate adapter fit in the target project.',
          ),
        ],
      );

  WorkshopLibraryApprovedHandoffRequest request({
    List<String> targets = const <String>['android'],
    List<String> allowed = const <String>['lib/demo.dart'],
  }) =>
      WorkshopLibraryApprovedHandoffRequest(
        taskId: 'library-task-1',
        title: 'Integrate certified demo capability',
        objective: 'Integrate the exact certified Library module.',
        pin: pin,
        capabilityId: 'demo.capability',
        contractId: 'demo.capability.v1',
        targets: targets,
        authorizedFileScope: WorkshopTaskFileScope(allowed: allowed),
      );

  test('verified certified package becomes planned Cantiere durable work',
      () async {
    final client = _FakeLibraryReadClient(
      state: state(),
      package: package(),
    );
    final handoff = await WorkshopLibraryApprovedHandoffService(
      client: client,
    ).prepare(request());

    expect(handoff.proof.pin, pin);
    expect(handoff.proof.snapshotSha256, snapshotSha);
    expect(handoff.proof.manifestSha256, manifestSha);
    expect(handoff.proof.moduleTreeSha256, treeSha);
    expect(handoff.proof.packageSha256, packageSha);

    final task = handoff.task;
    expect(task.status, WorkshopTaskStatus.planned);
    expect(task.kind, WorkshopTaskKind.integration);
    expect(task.metadata['libraryApprovedHandoff'], isTrue);
    expect(task.metadata['requiresProjectAuthorization'], isTrue);
    expect(task.fileScope.allowed, <String>['lib/demo.dart']);
    expect(task.tags, contains('library-approved'));
    expect(task.isAgentReady, isTrue);

    final durable = WorkshopDurableTaskProjection.fromContract(
      task,
      capabilityResolver: (value) =>
          value.metadata['durableCapability']?.toString() ?? '',
    );
    expect(durable.state, WorkshopDurableState.planning);
    expect(durable.capability, 'codeGeneration');
    expect(
      durable.completionCriterionIds,
      containsAll(<String>[
        'library_handoff_integrity_verified',
        'reviewer_approved',
        'validation_passed',
        'owner_apply_boundary_preserved',
      ]),
    );
  });

  test('handoff refuses non-active or under-validated certified assets',
      () async {
    final clients = <_FakeLibraryReadClient>[
      _FakeLibraryReadClient(
        state: state(
          availability: WorkshopLibraryCandidateAvailability.deprecated,
        ),
        package: package(
          availability: WorkshopLibraryCandidateAvailability.deprecated,
        ),
      ),
      _FakeLibraryReadClient(
        state: state(validationScore: 0.79),
        package: package(),
      ),
    ];
    for (final client in clients) {
      await expectLater(
        WorkshopLibraryApprovedHandoffService(client: client)
            .prepare(request()),
        throwsA(isA<WorkshopLibraryApprovedHandoffException>()),
      );
    }
  });

  test('handoff binds package manifest/tree and certified capability contract',
      () async {
    final clients = <_FakeLibraryReadClient>[
      _FakeLibraryReadClient(
        state: state(),
        package: package(
          packageManifestSha: List<String>.filled(64, 'e').join(),
        ),
      ),
      _FakeLibraryReadClient(
        state: state(),
        package: package(
          packageTreeSha: List<String>.filled(64, 'f').join(),
        ),
      ),
      _FakeLibraryReadClient(
        state: state(),
        package: package(capabilities: const <String>['other.capability']),
      ),
      _FakeLibraryReadClient(
        state: state(),
        package: package(contracts: const <String>['other.contract.v1']),
      ),
    ];

    for (final client in clients) {
      await expectLater(
        WorkshopLibraryApprovedHandoffService(client: client)
            .prepare(request()),
        throwsA(
          isA<WorkshopLibraryApprovedHandoffException>().having(
            (error) => error.code,
            'code',
            'package_snapshot_mismatch',
          ),
        ),
      );
    }
  });

  test('handoff cannot widen project-authorized file scope', () async {
    final client = _FakeLibraryReadClient(
      state: state(),
      package: package(targetPath: 'lib/outside.dart'),
    );
    await expectLater(
      WorkshopLibraryApprovedHandoffService(client: client)
          .prepare(request()),
      throwsA(
        isA<WorkshopLibraryApprovedHandoffException>().having(
          (error) => error.code,
          'code',
          'package_scope_violation',
        ),
      ),
    );
  });

  test('handoff rejects target capability and contract mismatches before load',
      () async {
    final client = _FakeLibraryReadClient(
      state: state(),
      package: package(),
    );

    final badRequests = <WorkshopLibraryApprovedHandoffRequest>[
      WorkshopLibraryApprovedHandoffRequest(
        taskId: 't1',
        title: 'x',
        objective: 'x',
        pin: pin,
        capabilityId: 'other.capability',
        contractId: 'demo.capability.v1',
        targets: const <String>['android'],
        authorizedFileScope:
            const WorkshopTaskFileScope(allowed: <String>['lib/demo.dart']),
      ),
      WorkshopLibraryApprovedHandoffRequest(
        taskId: 't2',
        title: 'x',
        objective: 'x',
        pin: pin,
        capabilityId: 'demo.capability',
        contractId: 'other.contract.v1',
        targets: const <String>['android'],
        authorizedFileScope:
            const WorkshopTaskFileScope(allowed: <String>['lib/demo.dart']),
      ),
      request(targets: const <String>['windows']),
    ];
    for (final badRequest in badRequests) {
      await expectLater(
        WorkshopLibraryApprovedHandoffService(client: client)
            .prepare(badRequest),
        throwsA(isA<WorkshopLibraryApprovedHandoffException>()),
      );
    }
  });
}

final class _FakeLibraryReadClient implements WorkshopLibraryReadClient {
  const _FakeLibraryReadClient({
    required this.state,
    required this.package,
  });

  final WorkshopLibraryRemoteState state;
  final WorkshopReusableModulePackage package;

  @override
  Future<WorkshopLibraryRemoteState> loadState() async => state;

  @override
  Future<WorkshopReusableModulePackage> loadPackage({
    required WorkshopLibraryRemoteState state,
    required String pin,
  }) async {
    if (pin != package.pin) {
      throw StateError('unexpected pin');
    }
    return package;
  }
}
