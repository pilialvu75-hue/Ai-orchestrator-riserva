import 'dart:convert';

enum WorkshopCertifiedLibraryEvidenceDisposition {
  staged,
  adaptationRequired,
}

final class WorkshopCertifiedLibrarySelectionEvidence {
  const WorkshopCertifiedLibrarySelectionEvidence({
    required this.pin,
    required this.capabilityId,
    required this.contractId,
    required this.targets,
  });

  final String pin;
  final String capabilityId;
  final String contractId;
  final List<String> targets;

  Map<String, Object?> toJson() => <String, Object?>{
        'pin': pin,
        'capabilityId': capabilityId,
        'contractId': contractId,
        'targets': targets,
      };
}

final class WorkshopCertifiedLibraryAssetEvidence {
  const WorkshopCertifiedLibraryAssetEvidence({
    required this.pin,
    required this.manifestSha256,
    required this.moduleTreeSha256,
    required this.packageSha256,
    required this.validationScore,
    required this.capabilities,
    required this.contracts,
    required this.targets,
  });

  final String pin;
  final String manifestSha256;
  final String moduleTreeSha256;
  final String packageSha256;
  final double validationScore;
  final List<String> capabilities;
  final List<String> contracts;
  final List<String> targets;

  Map<String, Object?> toJson() => <String, Object?>{
        'pin': pin,
        'manifestSha256': manifestSha256,
        'moduleTreeSha256': moduleTreeSha256,
        'packageSha256': packageSha256,
        'validationScore': validationScore,
        'capabilities': capabilities,
        'contracts': contracts,
        'targets': targets,
      };
}

final class WorkshopCertifiedLibraryRequirementEvidence {
  const WorkshopCertifiedLibraryRequirementEvidence({
    required this.kind,
    required this.description,
    required this.required,
  });

  final String kind;
  final String description;
  final bool required;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'description': description,
        'required': required,
      };
}

/// Read-only, transport-neutral proof that the Cantiere selected exact
/// certified Module Library bytes for the current project.
///
/// This evidence can guide Architect and Engineer reasoning, but it is never
/// project authorization, Reviewer approval, validation approval or guarded
/// apply authority.
final class WorkshopCertifiedLibraryEvidencePack {
  const WorkshopCertifiedLibraryEvidencePack({
    required this.libraryId,
    required this.catalogVersion,
    required this.snapshotSha256,
    required this.reuseIdentity,
    required this.disposition,
    required this.selections,
    required this.assets,
    required this.requirements,
    required this.stagedPaths,
    required this.identicalExistingPaths,
  });

  final String libraryId;
  final String catalogVersion;
  final String snapshotSha256;

  /// Deterministic identity already bound to the verified export and exact
  /// selected package envelopes.
  final String reuseIdentity;

  final WorkshopCertifiedLibraryEvidenceDisposition disposition;
  final List<WorkshopCertifiedLibrarySelectionEvidence> selections;
  final List<WorkshopCertifiedLibraryAssetEvidence> assets;
  final List<WorkshopCertifiedLibraryRequirementEvidence> requirements;
  final List<String> stagedPaths;
  final List<String> identicalExistingPaths;

  bool get requiresAdaptation =>
      disposition ==
      WorkshopCertifiedLibraryEvidenceDisposition.adaptationRequired;

  bool get hasRequiredRequirements =>
      requirements.any((item) => item.required);

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'libraryId': libraryId,
        'catalogVersion': catalogVersion,
        'snapshotSha256': snapshotSha256,
        'reuseIdentity': reuseIdentity,
        'disposition': disposition.name,
        'selections':
            selections.map((item) => item.toJson()).toList(growable: false),
        'assets': assets.map((item) => item.toJson()).toList(growable: false),
        'requirements':
            requirements.map((item) => item.toJson()).toList(growable: false),
        'stagedPaths': stagedPaths,
        'identicalExistingPaths': identicalExistingPaths,
        'requiresAdaptation': requiresAdaptation,
      };

  String toPromptContext() {
    return [
      'CERTIFIED MODULE LIBRARY EVIDENCE',
      jsonEncode(toJson()),
      'Treat this as verified provenance and integration evidence only.',
      'Use only the exact pinned assets and explicit requirements above.',
      'Do not widen project scope, substitute versions, or infer approval.',
    ].join('\n');
  }
}
