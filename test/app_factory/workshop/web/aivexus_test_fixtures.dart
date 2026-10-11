import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';

WorkshopWebProject aivexusProject(
  String id, {
  AivexusProjectExtension? extension,
}) => WorkshopWebProject(
  id: id,
  title: id,
  goal: 'Test specification',
  platforms: const ['Web'],
  status: WorkshopWebProjectStatus.draft,
  progress: 0,
  currentPhase: 'Bozza',
  currentItem: 'Specifiche',
  createdAt: DateTime.utc(2026, 10, 11),
  updatedAt: DateTime.utc(2026, 10, 11),
  extension: extension,
);

final aivexusFixtureHash = List.filled(64, 'a').join();

// Metadata fixture only: this deliberately does not claim to be a valid GLB.
Map<String, Object?> aivexusArtifact() => {
  'ref': 'sha256:$aivexusFixtureHash',
  'name': 'fixture.glb',
  'role': 'mesh',
  'format': 'GLB',
  'mimeType': 'model/gltf-binary',
  'sizeBytes': 3,
  'sha256': aivexusFixtureHash,
  'sourceSpecRevision': 1,
  'geometryType': 'mesh',
  'units': 'm',
  'generator': {'name': 'fixture', 'version': '1', 'jobRef': 'test:producer'},
};

Map<String, Object?> aivexusRequest(String projectId) => {
  'requestId': 'test:request:1',
  'requesterProjectId': projectId,
  'requesterSpecRevision': 1,
  'producerDomain': 'cad',
  'consumerDomain': 'game',
  'requestedRole': 'mesh',
  'requestedFormat': 'GLB',
  'requirements': {'units': 'm'},
  'sourceRefs': <Object?>[],
  'licenseRequirement': 'original-user-content',
  'status': 'requested',
  'createdAt': '2026-10-11T10:00:00Z',
  'updatedAt': '2026-10-11T10:00:00Z',
  'jobRef': 'test:consumer',
};

Map<String, Object?> aivexusResult(String producerId) => {
  'requestId': 'test:request:1',
  'producerProjectId': producerId,
  'producerSpecRevision': 1,
  'artifactRef': 'sha256:$aivexusFixtureHash',
  'role': 'mesh',
  'format': 'GLB',
  'mimeType': 'model/gltf-binary',
  'sizeBytes': 3,
  'sha256': aivexusFixtureHash,
  'licenseRef': 'test:license',
  'provenance': {'source': 'synthetic-test-fixture'},
  'transformations': <Object?>[],
  'generator': {'name': 'fixture', 'version': '1', 'jobRef': 'test:producer'},
  'result': 'produced',
  'validationRefs': <String>[],
};
