enum WorkshopLibraryAssetKind {
  module,
  component,
  integrationBundle,
  architecturePattern,
  projectTemplate,
  policyBundle,
}

enum WorkshopLibraryPayloadType {
  repositoryPath,
  upstreamReference,
  archive,
}

enum WorkshopLibrarySubmissionIntegrationEffort {
  trivial,
  low,
  medium,
  high,
}

enum WorkshopLibraryIntegrationMode {
  package,
  adapter,
  sourceBundle,
  recipe,
  policy,
}

final class WorkshopLibraryDependency {
  const WorkshopLibraryDependency({
    required this.name,
    this.version,
    this.source,
  });

  final String name;
  final String? version;
  final String? source;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'version': version,
        'source': source,
      };
}

final class WorkshopLibraryLegoProvide {
  const WorkshopLibraryLegoProvide({
    required this.capabilityId,
    required this.contractId,
    this.contractVersion,
  });

  final String capabilityId;
  final String contractId;
  final String? contractVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'capability_id': capabilityId,
        'contract_id': contractId,
        if (contractVersion != null) 'contract_version': contractVersion,
      };
}

final class WorkshopLibraryLegoRequire {
  const WorkshopLibraryLegoRequire({
    required this.capabilityId,
    this.contractId,
    this.minimumContractVersion,
    this.optional = false,
  });

  final String capabilityId;
  final String? contractId;
  final String? minimumContractVersion;
  final bool optional;

  Map<String, Object?> toJson() => <String, Object?>{
        'capability_id': capabilityId,
        'contract_id': contractId,
        'minimum_contract_version': minimumContractVersion,
        'optional': optional,
      };
}

final class WorkshopLibraryLegoAdapter {
  const WorkshopLibraryLegoAdapter({
    required this.target,
    required this.entryPath,
    this.framework,
    this.adapterContract,
  });

  final String target;
  final String entryPath;
  final String? framework;
  final String? adapterContract;

  Map<String, Object?> toJson() => <String, Object?>{
        'target': target,
        'framework': framework,
        'entry_path': entryPath,
        'adapter_contract': adapterContract,
      };
}

final class WorkshopLibraryConnectorEvidence {
  const WorkshopLibraryConnectorEvidence({
    required this.provides,
    this.requires = const <WorkshopLibraryLegoRequire>[],
    this.integrationMode = WorkshopLibraryIntegrationMode.sourceBundle,
    this.adapters = const <WorkshopLibraryLegoAdapter>[],
    this.configurationSchema,
    this.healthcheckType = 'none',
    this.healthcheckPath,
    this.standardVersion = '1.0.0',
  });

  final List<WorkshopLibraryLegoProvide> provides;
  final List<WorkshopLibraryLegoRequire> requires;
  final WorkshopLibraryIntegrationMode integrationMode;
  final List<WorkshopLibraryLegoAdapter> adapters;
  final String? configurationSchema;
  final String healthcheckType;
  final String? healthcheckPath;
  final String standardVersion;
}

final class WorkshopLibraryPayloadEvidence {
  const WorkshopLibraryPayloadEvidence({
    required this.type,
    required this.sha256,
    this.path,
    this.upstreamRepository,
    this.upstreamCommit,
  });

  final WorkshopLibraryPayloadType type;
  final String sha256;
  final String? path;
  final String? upstreamRepository;
  final String? upstreamCommit;
}

/// Evidence the Cantiere must possess before it may prepare a candidate for
/// the external Module Library intake.
///
/// This model is transport-free and cannot write to GitHub or the Library.
final class WorkshopLibraryCaptureEvidence {
  const WorkshopLibraryCaptureEvidence({
    required this.assetId,
    required this.name,
    required this.version,
    required this.kind,
    required this.description,
    required this.capabilities,
    required this.platforms,
    required this.sourceProjectId,
    required this.license,
    required this.validationScore,
    required this.testsPassed,
    required this.securityReviewed,
    required this.knownVulnerabilities,
    required this.integrationEffort,
    required this.adaptationAllowed,
    required this.connector,
    required this.payload,
    this.sourceTaskId,
    this.tags = const <String>[],
    this.languages = const <String>[],
    this.frameworks = const <String>[],
    this.entryPaths = const <String>[],
    this.dependencies = const <WorkshopLibraryDependency>[],
    this.licenseFile,
    this.testReport,
    this.validatedAt,
    this.validatedOn = const <String>[],
    this.securityReviewedAt,
    this.sbom,
    this.securityNotes,
    this.knownConstraints = const <String>[],
    this.adapterNotes,
    this.generatedAt,
  });

  final String assetId;
  final String name;
  final String version;
  final WorkshopLibraryAssetKind kind;
  final String description;
  final List<String> capabilities;
  final List<String> platforms;
  final String sourceProjectId;
  final String? sourceTaskId;
  final String license;
  final String? licenseFile;
  final double validationScore;
  final bool testsPassed;
  final String? testReport;
  final DateTime? validatedAt;
  final List<String> validatedOn;
  final bool securityReviewed;
  final DateTime? securityReviewedAt;
  final int knownVulnerabilities;
  final String? sbom;
  final String? securityNotes;
  final WorkshopLibrarySubmissionIntegrationEffort integrationEffort;
  final bool adaptationAllowed;
  final List<String> knownConstraints;
  final String? adapterNotes;
  final WorkshopLibraryConnectorEvidence connector;
  final WorkshopLibraryPayloadEvidence payload;
  final List<String> tags;
  final List<String> languages;
  final List<String> frameworks;
  final List<String> entryPaths;
  final List<WorkshopLibraryDependency> dependencies;
  final DateTime? generatedAt;
}

/// Exact, untrusted intake envelope ready for a later transport bridge.
///
/// It deliberately points to `intake/...`, never `modules/...`, and the
/// manifest status is always `discovered`. Only the Library promotion pipeline
/// can later certify the candidate.
final class WorkshopLibraryIntakeSubmission {
  const WorkshopLibraryIntakeSubmission({
    required this.assetId,
    required this.version,
    required this.manifest,
    required this.sourceProjectId,
    required this.sourceTaskId,
    required this.payloadSha256,
  });

  final String assetId;
  final String version;
  final Map<String, Object?> manifest;
  final String sourceProjectId;
  final String? sourceTaskId;
  final String payloadSha256;

  String get pin => '$assetId@$version';
  String get intakeDirectory => 'intake/$assetId/$version';
  String get manifestPath => '$intakeDirectory/manifest.json';

  Map<String, Object?> toJson() => <String, Object?>{
        'pin': pin,
        'intake_directory': intakeDirectory,
        'manifest_path': manifestPath,
        'payload_sha256': payloadSha256,
        'manifest': manifest,
      };
}

final class WorkshopLibraryCaptureDecision {
  const WorkshopLibraryCaptureDecision._({
    required this.accepted,
    required this.reasons,
    this.submission,
  });

  final bool accepted;
  final List<String> reasons;
  final WorkshopLibraryIntakeSubmission? submission;

  factory WorkshopLibraryCaptureDecision.accept(
    WorkshopLibraryIntakeSubmission submission,
  ) {
    return WorkshopLibraryCaptureDecision._(
      accepted: true,
      reasons: const <String>[],
      submission: submission,
    );
  }

  factory WorkshopLibraryCaptureDecision.reject(List<String> reasons) {
    return WorkshopLibraryCaptureDecision._(
      accepted: false,
      reasons: List<String>.unmodifiable(reasons),
    );
  }
}

/// Strict Cantiere-side capture gate for the external Module Library.
///
/// A locally reusable descriptor is not automatically publishable. The gate
/// requires validation, tests, security review, traceability, Lego compatibility
/// and a SHA-256 pinned payload. Accepted output is still untrusted Library
/// intake and can never self-certify.
final class WorkshopLibrarySubmissionGate {
  const WorkshopLibrarySubmissionGate({
    this.minimumValidationScore = 0.8,
  }) : assert(minimumValidationScore >= 0 && minimumValidationScore <= 1);

  final double minimumValidationScore;

  static final RegExp _assetId =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$');
  static final RegExp _semver = RegExp(
    r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  static final RegExp _contractVersion = RegExp(r'^[0-9]+\.[0-9]+$');
  static final RegExp _standardVersion = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$');
  static final RegExp _sha256 = RegExp(r'^[A-Fa-f0-9]{64}$');

  WorkshopLibraryCaptureDecision evaluate(WorkshopLibraryCaptureEvidence evidence) {
    final reasons = <String>[];

    final assetId = evidence.assetId.trim();
    final name = evidence.name.trim();
    final version = evidence.version.trim();
    final description = evidence.description.trim();
    final sourceProjectId = evidence.sourceProjectId.trim();
    final sourceTaskId = _optional(evidence.sourceTaskId);
    final license = evidence.license.trim();
    final capabilities = _normalizedList(evidence.capabilities);
    final platforms = _normalizedList(evidence.platforms);
    final tags = _normalizedList(evidence.tags);
    final languages = _normalizedList(evidence.languages);
    final frameworks = _normalizedList(evidence.frameworks);
    final entryPaths = _normalizedList(evidence.entryPaths);
    final validatedOn = _normalizedList(evidence.validatedOn);
    final constraints = _normalizedList(evidence.knownConstraints);
    final evidenceAt = evidence.generatedAt ??
        evidence.validatedAt ??
        evidence.securityReviewedAt;

    if (!_assetId.hasMatch(assetId)) reasons.add('invalid-asset-id');
    if (name.isEmpty) reasons.add('missing-name');
    if (!_semver.hasMatch(version)) reasons.add('invalid-semver-version');
    if (description.isEmpty) reasons.add('missing-description');
    if (capabilities.isEmpty) reasons.add('missing-capabilities');
    if (platforms.isEmpty) reasons.add('missing-platforms');
    if (sourceProjectId.isEmpty) reasons.add('missing-source-project-id');
    if (license.isEmpty) reasons.add('missing-license-declaration');
    if (evidenceAt == null) reasons.add('missing-evidence-timestamp');

    if (evidence.validationScore < minimumValidationScore ||
        evidence.validationScore > 1) {
      reasons.add('validation-score-below-threshold');
    }
    if (!evidence.testsPassed) reasons.add('tests-not-passed');
    if (!evidence.securityReviewed) reasons.add('security-not-reviewed');
    if (evidence.knownVulnerabilities < 0) {
      reasons.add('invalid-vulnerability-count');
    } else if (evidence.knownVulnerabilities > 0) {
      reasons.add('known-vulnerabilities-require-manual-review');
    }

    _validateConnector(
      evidence.connector,
      declaredCapabilities: capabilities,
      platforms: platforms,
      reasons: reasons,
    );
    _validatePayload(evidence.payload, reasons);
    _validateDependencies(evidence.dependencies, reasons);
    _validateEntryPaths(entryPaths, reasons);

    if (reasons.isNotEmpty) {
      return WorkshopLibraryCaptureDecision.reject(_dedupe(reasons));
    }

    final generatedAt = evidenceAt!.toUtc();
    final manifest = <String, Object?>{
      'id': assetId,
      'name': name,
      'version': version,
      'kind': _assetKindName(evidence.kind),
      'status': 'discovered',
      'description': description,
      'tags': tags,
      'capabilities': capabilities,
      'platforms': platforms,
      'languages': languages,
      'frameworks': frameworks,
      'entry_paths': entryPaths,
      'dependencies': evidence.dependencies
          .map(
            (item) => WorkshopLibraryDependency(
              name: item.name.trim(),
              version: _optional(item.version),
              source: _optional(item.source),
            ).toJson(),
          )
          .toList(growable: false),
      'provenance': <String, Object?>{
        'origin': 'cantiere',
        'source_repository': null,
        'source_commit': null,
        'source_tag': null,
        'source_project_id': sourceProjectId,
        'source_task_id': sourceTaskId,
        'license': license,
        'license_file': _optional(evidence.licenseFile),
        'retrieved_at': generatedAt.toIso8601String(),
      },
      'validation': <String, Object?>{
        'score': evidence.validationScore,
        'tests_passed': evidence.testsPassed,
        'test_report': _optional(evidence.testReport),
        'validated_at': evidence.validatedAt?.toUtc().toIso8601String(),
        'validated_on': validatedOn.isEmpty ? platforms : validatedOn,
      },
      'security': <String, Object?>{
        'reviewed': evidence.securityReviewed,
        'reviewed_at':
            evidence.securityReviewedAt?.toUtc().toIso8601String(),
        'known_vulnerabilities': evidence.knownVulnerabilities,
        'sbom': _optional(evidence.sbom),
        'notes': _optional(evidence.securityNotes),
      },
      'integration': <String, Object?>{
        'estimated_effort': evidence.integrationEffort.name,
        'adaptation_allowed': evidence.adaptationAllowed,
        'known_constraints': constraints,
        'adapter_notes': _optional(evidence.adapterNotes),
      },
      'connector': _connectorJson(evidence.connector),
      'payload': _payloadJson(evidence.payload),
    };

    return WorkshopLibraryCaptureDecision.accept(
      WorkshopLibraryIntakeSubmission(
        assetId: assetId,
        version: version,
        manifest: Map<String, Object?>.unmodifiable(manifest),
        sourceProjectId: sourceProjectId,
        sourceTaskId: sourceTaskId,
        payloadSha256: evidence.payload.sha256.trim().toLowerCase(),
      ),
    );
  }

  void _validateConnector(
    WorkshopLibraryConnectorEvidence connector, {
    required List<String> declaredCapabilities,
    required List<String> platforms,
    required List<String> reasons,
  }) {
    if (!_standardVersion.hasMatch(connector.standardVersion.trim())) {
      reasons.add('invalid-lego-standard-version');
    }
    if (connector.provides.isEmpty) reasons.add('missing-lego-provides');

    final provideKeys = <String>{};
    for (final provide in connector.provides) {
      final capability = provide.capabilityId.trim();
      final contract = provide.contractId.trim();
      final contractVersion = _optional(provide.contractVersion);
      if (capability.length < 3 || contract.length < 3) {
        reasons.add('invalid-lego-provide');
        continue;
      }
      if (!declaredCapabilities.contains(capability)) {
        reasons.add('lego-provide-capability-not-declared:$capability');
      }
      if (contractVersion != null && !_contractVersion.hasMatch(contractVersion)) {
        reasons.add('invalid-lego-contract-version:$contract');
      }
      if (!provideKeys.add('$capability|$contract')) {
        reasons.add('duplicate-lego-provide:$capability|$contract');
      }
    }

    final requireKeys = <String>{};
    for (final requirement in connector.requires) {
      final capability = requirement.capabilityId.trim();
      if (capability.length < 3) {
        reasons.add('invalid-lego-require');
        continue;
      }
      final contract = _optional(requirement.contractId);
      final minimum = _optional(requirement.minimumContractVersion);
      if (minimum != null && !_contractVersion.hasMatch(minimum)) {
        reasons.add('invalid-minimum-contract-version:$capability');
      }
      if (!requireKeys.add('$capability|${contract ?? ''}|${requirement.optional}')) {
        reasons.add('duplicate-lego-require:$capability');
      }
    }

    final adapterKeys = <String>{};
    for (final adapter in connector.adapters) {
      final target = adapter.target.trim();
      final entryPath = adapter.entryPath.trim();
      if (target.isEmpty || entryPath.isEmpty || !_isSafeRelativePath(entryPath)) {
        reasons.add('invalid-lego-adapter');
        continue;
      }
      if (!platforms.contains(target)) {
        reasons.add('lego-adapter-target-not-declared:$target');
      }
      if (!adapterKeys.add('$target|$entryPath')) {
        reasons.add('duplicate-lego-adapter:$target|$entryPath');
      }
    }

    final configurationSchema = _optional(connector.configurationSchema);
    if (configurationSchema != null &&
        !_isSafeRelativePath(configurationSchema)) {
      reasons.add('invalid-lego-configuration-schema');
    }

    final healthcheckType = connector.healthcheckType.trim();
    if (!const <String>{'test', 'probe', 'none'}.contains(healthcheckType)) {
      reasons.add('invalid-lego-healthcheck-type');
    }
    final healthcheckPath = _optional(connector.healthcheckPath);
    if (healthcheckType != 'none' &&
        (healthcheckPath == null || !_isSafeRelativePath(healthcheckPath))) {
      reasons.add('invalid-lego-healthcheck-path');
    }
  }

  void _validatePayload(
    WorkshopLibraryPayloadEvidence payload,
    List<String> reasons,
  ) {
    if (!_sha256.hasMatch(payload.sha256.trim())) {
      reasons.add('invalid-payload-sha256');
    }

    final path = _optional(payload.path);
    final repository = _optional(payload.upstreamRepository);
    final commit = _optional(payload.upstreamCommit);

    switch (payload.type) {
      case WorkshopLibraryPayloadType.repositoryPath:
      case WorkshopLibraryPayloadType.archive:
        if (path == null || !_isSafeRelativePath(path)) {
          reasons.add('invalid-payload-path');
        }
        break;
      case WorkshopLibraryPayloadType.upstreamReference:
        if (repository == null || commit == null) {
          reasons.add('incomplete-upstream-reference');
        }
        break;
    }
  }

  void _validateDependencies(
    List<WorkshopLibraryDependency> dependencies,
    List<String> reasons,
  ) {
    final seen = <String>{};
    for (final dependency in dependencies) {
      final name = dependency.name.trim();
      if (name.isEmpty) {
        reasons.add('dependency-name-missing');
        continue;
      }
      if (!seen.add(name.toLowerCase())) {
        reasons.add('duplicate-dependency:$name');
      }
    }
  }

  void _validateEntryPaths(List<String> entryPaths, List<String> reasons) {
    for (final path in entryPaths) {
      if (!_isSafeRelativePath(path)) {
        reasons.add('invalid-entry-path:$path');
      }
    }
  }

  Map<String, Object?> _connectorJson(
    WorkshopLibraryConnectorEvidence connector,
  ) {
    return <String, Object?>{
      'standard': 'ai-orchestrator-lego',
      'standard_version': connector.standardVersion.trim(),
      'provides': connector.provides
          .map(
            (item) => <String, Object?>{
              'capability_id': item.capabilityId.trim(),
              'contract_id': item.contractId.trim(),
              if (_optional(item.contractVersion) != null)
                'contract_version': _optional(item.contractVersion),
            },
          )
          .toList(growable: false),
      'requires': connector.requires
          .map(
            (item) => <String, Object?>{
              'capability_id': item.capabilityId.trim(),
              'contract_id': _optional(item.contractId),
              'minimum_contract_version':
                  _optional(item.minimumContractVersion),
              'optional': item.optional,
            },
          )
          .toList(growable: false),
      'integration_mode': _integrationModeName(connector.integrationMode),
      if (connector.adapters.isNotEmpty)
        'adapters': connector.adapters
            .map(
              (item) => <String, Object?>{
                'target': item.target.trim(),
                'framework': _optional(item.framework),
                'entry_path': item.entryPath.trim(),
                'adapter_contract': _optional(item.adapterContract),
              },
            )
            .toList(growable: false),
      'configuration_schema': _optional(connector.configurationSchema),
      'healthcheck': <String, Object?>{
        'type': connector.healthcheckType.trim(),
        'path': _optional(connector.healthcheckPath),
      },
    };
  }

  Map<String, Object?> _payloadJson(WorkshopLibraryPayloadEvidence payload) {
    return <String, Object?>{
      'type': _payloadTypeName(payload.type),
      'path': _optional(payload.path),
      'sha256': payload.sha256.trim().toLowerCase(),
      'upstream_repository': _optional(payload.upstreamRepository),
      'upstream_commit': _optional(payload.upstreamCommit),
    };
  }

  static bool _isSafeRelativePath(String value) {
    final raw = value.trim();
    if (raw.isEmpty ||
        raw.startsWith('/') ||
        raw.startsWith('~') ||
        raw.contains('\\') ||
        raw.contains(':') ||
        raw.contains('\u0000')) {
      return false;
    }

    final path = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    if (path.isEmpty) return false;
    final segments = path.split('/');
    return !segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    );
  }

  static String? _optional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _normalizedList(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized)) result.add(normalized);
    }
    result.sort();
    return List<String>.unmodifiable(result);
  }

  static List<String> _dedupe(Iterable<String> values) {
    final result = values.toSet().toList()..sort();
    return List<String>.unmodifiable(result);
  }
}

String _assetKindName(WorkshopLibraryAssetKind value) => switch (value) {
      WorkshopLibraryAssetKind.module => 'module',
      WorkshopLibraryAssetKind.component => 'component',
      WorkshopLibraryAssetKind.integrationBundle => 'integration_bundle',
      WorkshopLibraryAssetKind.architecturePattern => 'architecture_pattern',
      WorkshopLibraryAssetKind.projectTemplate => 'project_template',
      WorkshopLibraryAssetKind.policyBundle => 'policy_bundle',
    };

String _payloadTypeName(WorkshopLibraryPayloadType value) => switch (value) {
      WorkshopLibraryPayloadType.repositoryPath => 'repository_path',
      WorkshopLibraryPayloadType.upstreamReference => 'upstream_reference',
      WorkshopLibraryPayloadType.archive => 'archive',
    };

String _integrationModeName(WorkshopLibraryIntegrationMode value) =>
    switch (value) {
      WorkshopLibraryIntegrationMode.package => 'package',
      WorkshopLibraryIntegrationMode.adapter => 'adapter',
      WorkshopLibraryIntegrationMode.sourceBundle => 'source_bundle',
      WorkshopLibraryIntegrationMode.recipe => 'recipe',
      WorkshopLibraryIntegrationMode.policy => 'policy',
    };
