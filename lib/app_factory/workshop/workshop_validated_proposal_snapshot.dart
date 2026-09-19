import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Lightweight descriptor of one validated, not-yet-applied proposal snapshot.
///
/// The descriptor is safe to reference from the Execution journal. Source
/// contents are never embedded here or in SharedPreferences; they live under
/// [rootPath] in a dedicated application-owned recovery directory.
final class WorkshopValidatedProposalSnapshot {
  const WorkshopValidatedProposalSnapshot({
    required this.executionId,
    required this.attemptId,
    required this.projectId,
    required this.taskId,
    required this.requestId,
    required this.rootPath,
    required this.manifestSha256,
    required this.createdAt,
  });

  final String executionId;
  final String attemptId;
  final String projectId;
  final String taskId;
  final String requestId;
  final String rootPath;
  final String manifestSha256;
  final DateTime createdAt;

  Map<String, dynamic> toExecutionMetadata() => <String, dynamic>{
        'validatedProposalSnapshot': <String, dynamic>{
          'schema': WorkshopValidatedProposalSnapshotService.schema,
          'executionId': executionId,
          'attemptId': attemptId,
          'projectId': projectId,
          'taskId': taskId,
          'requestId': requestId,
          'rootPath': rootPath,
          'manifestSha256': manifestSha256,
          'createdAt': createdAt.toUtc().toIso8601String(),
        },
      };

  factory WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
    Map<String, dynamic> metadata,
  ) {
    final raw = metadata['validatedProposalSnapshot'];
    if (raw is! Map) {
      throw const FormatException(
        'Validated proposal snapshot metadata is missing.',
      );
    }

    final json = Map<String, dynamic>.from(raw);
    if (json['schema'] != WorkshopValidatedProposalSnapshotService.schema) {
      throw const FormatException(
        'Validated proposal snapshot schema is unsupported.',
      );
    }

    final createdAt = DateTime.tryParse(
      json['createdAt']?.toString() ?? '',
    )?.toUtc();
    if (createdAt == null) {
      throw const FormatException(
        'Validated proposal snapshot createdAt is invalid.',
      );
    }

    return WorkshopValidatedProposalSnapshot(
      executionId: _requiredString(json, 'executionId'),
      attemptId: _requiredString(json, 'attemptId'),
      projectId: _requiredString(json, 'projectId'),
      taskId: _requiredString(json, 'taskId'),
      requestId: _requiredString(json, 'requestId'),
      rootPath: _requiredString(json, 'rootPath'),
      manifestSha256: _requiredSha(json, 'manifestSha256'),
      createdAt: createdAt,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw FormatException('Validated proposal snapshot $key is missing.');
    }
    return value;
  }

  static String _requiredSha(Map<String, dynamic> json, String key) {
    final value = _requiredString(json, key).toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw FormatException('Validated proposal snapshot $key is invalid.');
    }
    return value;
  }
}

final class WorkshopValidatedProposalBaselineConflict implements Exception {
  const WorkshopValidatedProposalBaselineConflict(this.path);

  final String path;

  @override
  String toString() =>
      'Validated proposal baseline changed after snapshot: $path';
}

/// Disk-backed recovery snapshot for a proposal that already passed Reviewer
/// and validation but has not yet crossed the explicit owner approval/apply
/// boundary.
///
/// Security properties:
/// - snapshot root is application-owned and separate from the live repository;
/// - only the same source/text path allow-list used by verified reuse is stored;
/// - symlinks are never accepted as snapshot directories/files;
/// - file count/size/text fields are bounded;
/// - every stored file and the manifest are SHA-256 verified;
/// - the live workspace baseline must still match the pre-crash baseline;
/// - restoring reconstructs a proposal/result only: it never writes to the live
///   repository and never grants owner apply approval.
final class WorkshopValidatedProposalSnapshotService {
  WorkshopValidatedProposalSnapshotService({
    required String snapshotsRootPath,
    this.maxFileSizeBytes = 2 * 1024 * 1024,
    this.maxTotalBytes = 16 * 1024 * 1024,
    this.maxChanges = 256,
    this.maxTextChars = 2000,
    this.maxTextItems = 32,
  }) : snapshotsRootPath = Directory(snapshotsRootPath).absolute.path;

  static const String schema =
      'ai-orchestrator.workshop.validated-proposal-snapshot.v1';

  final String snapshotsRootPath;
  final int maxFileSizeBytes;
  final int maxTotalBytes;
  final int maxChanges;
  final int maxTextChars;
  final int maxTextItems;

  Future<WorkshopValidatedProposalSnapshot> capture({
    required String executionId,
    required String attemptId,
    required String projectId,
    required String taskId,
    required WorkshopTaskInferenceResult result,
    required Map<String, String> baselineSnapshot,
    required Map<String, String> stagedSnapshot,
  }) async {
    _validateLimits();

    if (!result.readyForApproval ||
        !result.review.approved ||
        result.validation?.valid != true) {
      throw StateError(
        'Only a Workshop result that passed review and validation can be '
        'captured for approval recovery.',
      );
    }

    final baseline = _normalizedBaseline(baselineSnapshot);
    final staged = _normalizedBaseline(stagedSnapshot);
    final changes = WorkspaceDiff.compare(
      before: baseline,
      after: staged,
    ).changes;
    if (changes.isEmpty) {
      throw StateError(
        'Validated proposal recovery requires a non-empty staged workspace diff.',
      );
    }
    if (changes.length > maxChanges) {
      throw StateError(
        'Validated proposal exceeds the recovery change limit ($maxChanges).',
      );
    }

    final normalizedExecutionId = _identity(executionId, 'executionId');
    final normalizedAttemptId = _identity(attemptId, 'attemptId');
    final normalizedProjectId = _identity(projectId, 'projectId');
    final normalizedTaskId = _identity(taskId, 'taskId');
    final requestId = _identity(result.proposal.requestId, 'requestId');

    final root = Directory(snapshotsRootPath).absolute;
    await root.create(recursive: true);
    final rootType = await FileSystemEntity.type(
      root.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw StateError(
        'Validated proposal recovery root is unavailable or unsafe.',
      );
    }

    final executionDirectory = Directory(
      p.join(root.path, _safeDirectoryName(normalizedExecutionId)),
    ).absolute;
    await _ensureOwnedDirectory(
      directory: executionDirectory,
      parent: root,
    );

    final finalDirectory = Directory(
      p.join(
        executionDirectory.path,
        _safeDirectoryName(normalizedAttemptId),
      ),
    ).absolute;
    _ensureStrictlyInside(finalDirectory.path, root.path);

    final tempDirectory = Directory(
      '${finalDirectory.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    ).absolute;
    _ensureStrictlyInside(tempDirectory.path, root.path);
    final tempType = await FileSystemEntity.type(
      tempDirectory.path,
      followLinks: false,
    );
    if (tempType != FileSystemEntityType.notFound) {
      throw StateError(
        'Validated proposal temporary recovery directory already exists.',
      );
    }
    await tempDirectory.create();

    final manifestChanges = <Map<String, dynamic>>[];
    var totalBytes = 0;

    try {
      final seen = <String>{};
      for (final change in changes) {
        final relative = _normalizeRelative(change.path);
        if (!seen.add(relative)) {
          throw StateError(
            'Validated proposal contains duplicate path "$relative".',
          );
        }
        if (!WorkshopReuseSourceSnapshotService.isSafeReusablePath(relative)) {
          throw StateError(
            'Validated proposal path is not safe for recovery: "$relative".',
          );
        }

        final baselinePresent = baseline.containsKey(relative);
        final baselineContent = baseline[relative];
        if (change.isAddition && baselinePresent) {
          throw WorkshopValidatedProposalBaselineConflict(relative);
        }
        if ((change.isModification || change.isDeletion) &&
            !baselinePresent) {
          throw WorkshopValidatedProposalBaselineConflict(relative);
        }
        final baselineSha256 = baselineContent == null
            ? null
            : sha256.convert(utf8.encode(baselineContent)).toString();

        if (change.isDeletion) {
          manifestChanges.add(<String, dynamic>{
            'path': relative,
            'type': WorkspaceChangeType.deletion.name,
            'bytes': 0,
            'sha256': null,
            'baselinePresent': true,
            'baselineSha256': baselineSha256,
          });
          continue;
        }

        final content = change.afterContent;
        if (content == null) {
          throw StateError(
            'Validated proposal change "$relative" has no afterContent.',
          );
        }

        final bytes = utf8.encode(content);
        if (bytes.length > maxFileSizeBytes) {
          throw StateError(
            'Validated proposal file "$relative" exceeds '
            '$maxFileSizeBytes bytes.',
          );
        }
        totalBytes += bytes.length;
        if (totalBytes > maxTotalBytes) {
          throw StateError(
            'Validated proposal exceeds $maxTotalBytes recovery bytes.',
          );
        }

        final destination = File(
          p.join(tempDirectory.path, 'files', relative),
        ).absolute;
        _ensureStrictlyInside(destination.path, tempDirectory.path);
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes, flush: true);

        manifestChanges.add(<String, dynamic>{
          'path': relative,
          'type': change.type.name,
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'baselinePresent': baselinePresent,
          'baselineSha256': baselineSha256,
        });
      }

      final validation = result.validation!;
      final createdAt = DateTime.now().toUtc();
      final payload = <String, dynamic>{
        'schema': schema,
        'executionId': normalizedExecutionId,
        'attemptId': normalizedAttemptId,
        'projectId': normalizedProjectId,
        'taskId': normalizedTaskId,
        'requestId': requestId,
        'createdAt': createdAt.toIso8601String(),
        'totalBytes': totalBytes,
        'changes': manifestChanges,
        'review': <String, dynamic>{
          'approved': true,
          'summary': _boundedText(result.review.summary, 'review.summary'),
          'findings': _boundedStrings(
            result.review.findings,
            'review.findings',
          ),
          'warnings': _boundedStrings(
            result.review.warnings,
            'review.warnings',
          ),
        },
        'validation': <String, dynamic>{
          'valid': true,
          'summary': _boundedText(validation.summary, 'validation.summary'),
          'checks': _boundedStrings(validation.checks, 'validation.checks'),
          'warnings':
              _boundedStrings(validation.warnings, 'validation.warnings'),
        },
      };

      final canonical = jsonEncode(payload);
      final manifestSha256 =
          sha256.convert(utf8.encode(canonical)).toString();
      final manifestFile = File(p.join(tempDirectory.path, 'snapshot.json'));
      await manifestFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...payload,
          'manifestSha256': manifestSha256,
        }),
        flush: true,
      );

      final finalType = await FileSystemEntity.type(
        finalDirectory.path,
        followLinks: false,
      );
      if (finalType != FileSystemEntityType.notFound) {
        if (finalType != FileSystemEntityType.directory) {
          throw StateError(
            'Validated proposal recovery destination is unsafe.',
          );
        }
        await _ensureResolvedDirectoryInside(
          finalDirectory.path,
          root.path,
        );
        await finalDirectory.delete(recursive: true);
      }
      await tempDirectory.rename(finalDirectory.path);

      return WorkshopValidatedProposalSnapshot(
        executionId: normalizedExecutionId,
        attemptId: normalizedAttemptId,
        projectId: normalizedProjectId,
        taskId: normalizedTaskId,
        requestId: requestId,
        rootPath: finalDirectory.path,
        manifestSha256: manifestSha256,
        createdAt: createdAt,
      );
    } catch (_) {
      final type = await FileSystemEntity.type(
        tempDirectory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        await tempDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<WorkshopTaskInferenceResult> restore({
    required WorkshopValidatedProposalSnapshot snapshot,
    required Map<String, String> currentBaselineSnapshot,
  }) async {
    _validateLimits();

    final configuredRoot = Directory(snapshotsRootPath).absolute.path;
    final snapshotRoot = Directory(snapshot.rootPath).absolute.path;
    _ensureStrictlyInside(snapshotRoot, configuredRoot);
    await _ensureResolvedDirectoryInside(snapshotRoot, configuredRoot);

    final manifestFile = File(p.join(snapshotRoot, 'snapshot.json')).absolute;
    _ensureStrictlyInside(manifestFile.path, snapshotRoot);
    final manifestType = await FileSystemEntity.type(
      manifestFile.path,
      followLinks: false,
    );
    if (manifestType != FileSystemEntityType.file) {
      throw StateError(
        'Validated proposal recovery manifest is unavailable or unsafe.',
      );
    }
    await _ensureResolvedFileInside(manifestFile.path, snapshotRoot);

    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) {
      throw const FormatException(
        'Validated proposal recovery manifest is invalid.',
      );
    }
    final manifest = Map<String, dynamic>.from(decoded);
    final declaredManifestSha =
        manifest['manifestSha256']?.toString().trim().toLowerCase();
    final payload = Map<String, dynamic>.from(manifest)
      ..remove('manifestSha256');
    final computedManifestSha =
        sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    if (declaredManifestSha != computedManifestSha ||
        computedManifestSha != snapshot.manifestSha256.toLowerCase()) {
      throw const FormatException(
        'Validated proposal recovery manifest SHA-256 mismatch.',
      );
    }

    _expect(manifest, 'schema', schema);
    _expect(manifest, 'executionId', snapshot.executionId);
    _expect(manifest, 'attemptId', snapshot.attemptId);
    _expect(manifest, 'projectId', snapshot.projectId);
    _expect(manifest, 'taskId', snapshot.taskId);
    _expect(manifest, 'requestId', snapshot.requestId);

    final rawChanges = manifest['changes'];
    if (rawChanges is! List || rawChanges.isEmpty) {
      throw const FormatException(
        'Validated proposal recovery changes are missing.',
      );
    }
    if (rawChanges.length > maxChanges) {
      throw StateError(
        'Validated proposal recovery exceeds the change limit ($maxChanges).',
      );
    }

    final baseline = _normalizedBaseline(currentBaselineSnapshot);
    final changes = <WorkspaceFileChange>[];
    final seen = <String>{};
    var totalBytes = 0;

    for (final raw in rawChanges) {
      if (raw is! Map) {
        throw const FormatException(
          'Validated proposal recovery change is invalid.',
        );
      }
      final entry = Map<String, dynamic>.from(raw);
      final relative = _normalizeRelative(_required(entry, 'path'));
      if (!seen.add(relative) ||
          !WorkshopReuseSourceSnapshotService.isSafeReusablePath(relative)) {
        throw FormatException(
          'Validated proposal recovery path is unsafe: $relative',
        );
      }

      final type = _decodeChangeType(_required(entry, 'type'));
      _verifyBaselineEntry(
        entry: entry,
        path: relative,
        currentBaselineSnapshot: baseline,
      );

      if (type == WorkspaceChangeType.deletion) {
        if (entry['bytes'] is! num ||
            (entry['bytes'] as num).toInt() != 0 ||
            entry['sha256'] != null) {
          throw FormatException(
            'Validated proposal deletion descriptor is invalid: $relative',
          );
        }
        changes.add(
          WorkspaceFileChange(
            path: relative,
            type: WorkspaceChangeType.deletion,
          ),
        );
        continue;
      }

      final contentFile =
          File(p.join(snapshotRoot, 'files', relative)).absolute;
      _ensureStrictlyInside(contentFile.path, snapshotRoot);
      final entityType = await FileSystemEntity.type(
        contentFile.path,
        followLinks: false,
      );
      if (entityType != FileSystemEntityType.file) {
        throw StateError(
          'Validated proposal recovery file is unavailable or unsafe: '
          '$relative',
        );
      }
      await _ensureResolvedFileInside(contentFile.path, snapshotRoot);

      final bytes = await contentFile.readAsBytes();
      if (bytes.length > maxFileSizeBytes) {
        throw StateError(
          'Validated proposal recovery file exceeds the size limit: $relative',
        );
      }
      totalBytes += bytes.length;
      if (totalBytes > maxTotalBytes) {
        throw StateError(
          'Validated proposal recovery exceeds the total size limit.',
        );
      }

      final declaredBytes = entry['bytes'];
      final declaredFileSha =
          entry['sha256']?.toString().trim().toLowerCase();
      final actualSha = sha256.convert(bytes).toString();
      if (declaredBytes is! num ||
          declaredBytes.toInt() != bytes.length ||
          declaredFileSha != actualSha) {
        throw FormatException(
          'Validated proposal recovery integrity mismatch: $relative',
        );
      }

      final content = utf8.decode(bytes, allowMalformed: false);
      changes.add(
        WorkspaceFileChange(
          path: relative,
          type: type,
          afterContent: content,
        ),
      );
    }

    final declaredTotalBytes = manifest['totalBytes'];
    if (declaredTotalBytes is! num ||
        declaredTotalBytes.toInt() != totalBytes) {
      throw const FormatException(
        'Validated proposal recovery total byte count mismatch.',
      );
    }

    final review = _map(manifest, 'review');
    final validation = _map(manifest, 'validation');
    if (review['approved'] != true || validation['valid'] != true) {
      throw const FormatException(
        'Validated proposal recovery verdict is not approved and valid.',
      );
    }

    final proposal = WorkshopChangeProposal(
      requestId: snapshot.requestId,
      explanation: 'Recovered validated proposal snapshot.',
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
    );
    return WorkshopTaskInferenceResult(
      proposal: proposal,
      review: WorkshopReviewVerdict(
        approved: true,
        summary: _validatedText(review, 'summary'),
        findings: _validatedStrings(review, 'findings'),
        warnings: _validatedStrings(review, 'warnings'),
      ),
      validation: WorkshopValidationVerdict(
        valid: true,
        summary: _validatedText(validation, 'summary'),
        checks: _validatedStrings(validation, 'checks'),
        warnings: _validatedStrings(validation, 'warnings'),
      ),
    );
  }

  Future<void> remove(WorkshopValidatedProposalSnapshot snapshot) async {
    final configuredRoot = Directory(snapshotsRootPath).absolute.path;
    final snapshotRoot = Directory(snapshot.rootPath).absolute.path;
    _ensureStrictlyInside(snapshotRoot, configuredRoot);

    final type = await FileSystemEntity.type(
      snapshotRoot,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw StateError(
        'Validated proposal recovery snapshot root is unsafe to remove.',
      );
    }

    await _ensureResolvedDirectoryInside(snapshotRoot, configuredRoot);
    await Directory(snapshotRoot).delete(recursive: true);
  }

  void _verifyBaselineEntry({
    required Map<String, dynamic> entry,
    required String path,
    required Map<String, String> currentBaselineSnapshot,
  }) {
    final expectedPresent = entry['baselinePresent'];
    if (expectedPresent is! bool) {
      throw FormatException(
        'Validated proposal recovery baseline presence is missing: $path',
      );
    }

    final actualPresent = currentBaselineSnapshot.containsKey(path);
    if (actualPresent != expectedPresent) {
      throw WorkshopValidatedProposalBaselineConflict(path);
    }

    final expectedSha = entry['baselineSha256'];
    if (!expectedPresent) {
      if (expectedSha != null) {
        throw FormatException(
          'Validated proposal recovery baseline hash is invalid: $path',
        );
      }
      return;
    }

    final normalizedExpectedSha =
        expectedSha?.toString().trim().toLowerCase();
    if (normalizedExpectedSha == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedExpectedSha)) {
      throw FormatException(
        'Validated proposal recovery baseline hash is invalid: $path',
      );
    }

    final currentContent = currentBaselineSnapshot[path];
    if (currentContent == null) {
      throw WorkshopValidatedProposalBaselineConflict(path);
    }
    final actualSha =
        sha256.convert(utf8.encode(currentContent)).toString();
    if (actualSha != normalizedExpectedSha) {
      throw WorkshopValidatedProposalBaselineConflict(path);
    }
  }

  void _validateLimits() {
    if (maxFileSizeBytes <= 0 ||
        maxTotalBytes <= 0 ||
        maxChanges <= 0 ||
        maxTextChars <= 0 ||
        maxTextItems <= 0) {
      throw StateError('Validated proposal recovery limits must be positive.');
    }
  }

  String _boundedText(String value, String field) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maxTextChars) {
      throw StateError(
        'Validated proposal $field exceeds the bounded recovery contract.',
      );
    }
    return normalized;
  }

  List<String> _boundedStrings(List<String> values, String field) {
    if (values.length > maxTextItems) {
      throw StateError(
        'Validated proposal $field exceeds the item limit.',
      );
    }
    return List<String>.unmodifiable(
      values.map((value) => _boundedText(value, field)),
    );
  }

  String _validatedText(Map<String, dynamic> json, String key) {
    final value = _required(json, key);
    if (value.length > maxTextChars) {
      throw FormatException(
        'Validated proposal recovery $key exceeds the text limit.',
      );
    }
    return value;
  }

  List<String> _validatedStrings(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! List || raw.length > maxTextItems) {
      throw FormatException(
        'Validated proposal recovery $key is invalid.',
      );
    }

    final values = <String>[];
    for (final item in raw) {
      final value = item?.toString().trim() ?? '';
      if (value.isEmpty || value.length > maxTextChars) {
        throw FormatException(
          'Validated proposal recovery $key contains invalid text.',
        );
      }
      values.add(value);
    }
    return List<String>.unmodifiable(values);
  }

  static Map<String, String> _normalizedBaseline(
    Map<String, String> source,
  ) {
    final normalized = <String, String>{};
    for (final entry in source.entries) {
      final path = _normalizeRelative(entry.key);
      if (normalized.containsKey(path)) {
        throw StateError(
          'Workspace baseline contains duplicate normalized path "$path".',
        );
      }
      normalized[path] = entry.value;
    }
    return normalized;
  }

  static WorkspaceChangeType _decodeChangeType(String name) {
    for (final type in WorkspaceChangeType.values) {
      if (type.name == name) return type;
    }
    throw FormatException(
      'Validated proposal recovery change type is invalid: $name',
    );
  }

  static Map<String, dynamic> _map(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = json[key];
    if (value is! Map) {
      throw FormatException(
        'Validated proposal recovery $key is invalid.',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  static void _expect(
    Map<String, dynamic> json,
    String key,
    String expected,
  ) {
    if (json[key]?.toString() != expected) {
      throw FormatException(
        'Validated proposal recovery $key does not match the journal.',
      );
    }
  }

  static String _required(Map<String, dynamic> json, String key) {
    final value = json[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw FormatException(
        'Validated proposal recovery $key is missing.',
      );
    }
    return value;
  }

  static String _identity(String value, String field) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, field, '$field cannot be empty.');
    }
    return normalized;
  }

  static String _normalizeRelative(String value) {
    final normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      throw FormatException(
        'Validated proposal recovery path must be relative: $value',
      );
    }

    final segments = normalized.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException(
        'Validated proposal recovery path is unsafe: $value',
      );
    }
    return segments.join('/');
  }

  static String _safeDirectoryName(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 32);

  static Future<void> _ensureOwnedDirectory({
    required Directory directory,
    required Directory parent,
  }) async {
    _ensureStrictlyInside(directory.path, parent.path);
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create();
    } else if (type != FileSystemEntityType.directory) {
      throw StateError(
        'Validated proposal recovery directory is unsafe.',
      );
    }
    await _ensureResolvedDirectoryInside(directory.path, parent.path);
  }

  static void _ensureStrictlyInside(
    String childValue,
    String parentValue,
  ) {
    final child = _normalizedAbsolute(childValue);
    final parent = _normalizedAbsolute(parentValue);
    if (child == parent || !child.startsWith('$parent/')) {
      throw StateError(
        'Validated proposal recovery snapshot must be inside, but not equal '
        'to, its configured root.',
      );
    }
  }

  static Future<void> _ensureResolvedDirectoryInside(
    String childPath,
    String parentPath,
  ) async {
    final childType = await FileSystemEntity.type(
      childPath,
      followLinks: false,
    );
    if (childType != FileSystemEntityType.directory) {
      throw StateError(
        'Validated proposal recovery directory is unavailable or unsafe.',
      );
    }

    final resolvedParent =
        await Directory(parentPath).resolveSymbolicLinks();
    final resolvedChild =
        await Directory(childPath).resolveSymbolicLinks();
    _ensureStrictlyInside(resolvedChild, resolvedParent);
  }

  static Future<void> _ensureResolvedFileInside(
    String filePath,
    String parentPath,
  ) async {
    final resolvedParent =
        await Directory(parentPath).resolveSymbolicLinks();
    final resolvedFile = await File(filePath).resolveSymbolicLinks();
    _ensureStrictlyInside(resolvedFile, resolvedParent);
  }

  static String _normalizedAbsolute(String value) {
    var normalized = p.normalize(value).replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
