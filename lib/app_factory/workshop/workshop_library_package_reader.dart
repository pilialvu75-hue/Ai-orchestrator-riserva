import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'workshop_capability_reuse_planner.dart';
import 'workshop_module_assembly_plan.dart';

/// Fail-closed decoder for the physical certified package emitted by the
/// private Module Library.
///
/// The caller must obtain [expectedPackageSha256] from the authenticated
/// transport response (or another trusted integrity channel) and
/// [expectedModuleTreeSha256] from the resolver/offline snapshot selected for
/// the exact asset pin. The decoder never performs network or credential work.
final class WorkshopLibraryPackageReader {
  const WorkshopLibraryPackageReader();

  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  WorkshopReusableModulePackage decode({
    required String envelopeJson,
    required String expectedPin,
    required String expectedPackageSha256,
    required String expectedManifestSha256,
    required String expectedModuleTreeSha256,
  }) {
    final normalizedExpectedPin = expectedPin.trim();
    final normalizedPackageSha = expectedPackageSha256.trim().toLowerCase();
    final normalizedManifestSha = expectedManifestSha256.trim().toLowerCase();
    final normalizedTreeSha = expectedModuleTreeSha256.trim().toLowerCase();

    if (normalizedExpectedPin.isEmpty || !normalizedExpectedPin.contains('@')) {
      throw const FormatException('Expected Library pin must be asset@version.');
    }
    if (!_sha256.hasMatch(normalizedPackageSha)) {
      throw const FormatException('Expected package SHA-256 is invalid.');
    }
    if (!_sha256.hasMatch(normalizedManifestSha)) {
      throw const FormatException('Expected manifest SHA-256 is invalid.');
    }
    if (!_sha256.hasMatch(normalizedTreeSha)) {
      throw const FormatException('Expected module tree SHA-256 is invalid.');
    }

    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Library package envelope must be an object.');
    }
    if (decoded['schema'] !=
        'ai-orchestrator.library-module-package-envelope.v1') {
      throw const FormatException('Unsupported Library package envelope schema.');
    }

    final package = decoded['package'];
    if (package is! Map<String, dynamic>) {
      throw const FormatException('Library package body is missing.');
    }
    final canonicalPackage = _canonicalJson(package);
    final computedPackageSha =
        sha256.convert(utf8.encode(canonicalPackage)).toString();
    final envelopePackageSha =
        decoded['package_sha256']?.toString().trim().toLowerCase() ?? '';

    if (!_sha256.hasMatch(envelopePackageSha) ||
        envelopePackageSha != computedPackageSha ||
        computedPackageSha != normalizedPackageSha) {
      throw const FormatException('Library package SHA-256 mismatch.');
    }

    if (package['schema'] != 'ai-orchestrator.library-module-package.v1') {
      throw const FormatException('Unsupported Library module package schema.');
    }

    final assetId = package['asset_id']?.toString().trim() ?? '';
    final version = package['version']?.toString().trim() ?? '';
    final pin = package['pin']?.toString().trim() ?? '';
    if (assetId.isEmpty || version.isEmpty || pin != '$assetId@$version') {
      throw const FormatException('Library package identity is inconsistent.');
    }
    if (pin != normalizedExpectedPin) {
      throw const FormatException('Library package pin differs from selected pin.');
    }

    final availability = switch (
        package['availability']?.toString().trim() ?? '') {
      'active' => WorkshopLibraryCandidateAvailability.active,
      'deprecated' => WorkshopLibraryCandidateAvailability.deprecated,
      'revoked' => throw const FormatException(
          'Revoked Library packages cannot be consumed.'),
      _ => throw const FormatException('Invalid Library package availability.'),
    };

    final integrity = package['integrity'];
    if (integrity is! Map<String, dynamic>) {
      throw const FormatException('Library package integrity metadata is missing.');
    }
    final manifestSha =
        integrity['manifest_sha256']?.toString().trim().toLowerCase() ?? '';
    final moduleTreeSha =
        integrity['module_tree_sha256']?.toString().trim().toLowerCase() ?? '';
    if (!_sha256.hasMatch(manifestSha) ||
        manifestSha != normalizedManifestSha) {
      throw const FormatException('Library manifest SHA-256 mismatch.');
    }
    if (!_sha256.hasMatch(moduleTreeSha) || moduleTreeSha != normalizedTreeSha) {
      throw const FormatException('Library module tree SHA-256 mismatch.');
    }

    final capabilities = _stringList(package['capabilities'], 'capabilities');
    final contracts = _stringList(package['contracts'], 'contracts');
    if (capabilities.isEmpty || contracts.isEmpty) {
      throw const FormatException(
        'Library package must declare capabilities and contracts.',
      );
    }

    final files = <WorkshopReusableModuleFile>[];
    final rawFiles = package['files'];
    if (rawFiles is! List) {
      throw const FormatException('Library package files must be an array.');
    }
    final seenTargets = <String>{};
    for (final raw in rawFiles) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Library package file must be an object.');
      }
      final sourcePath = raw['source_path']?.toString().trim() ?? '';
      final targetPath = raw['target_path']?.toString().trim() ?? '';
      final content = raw['content'];
      if (!_isSafePath(sourcePath) || !_isSafePath(targetPath)) {
        throw const FormatException('Library package contains an unsafe file path.');
      }
      if (!seenTargets.add(targetPath)) {
        throw const FormatException('Library package contains duplicate target paths.');
      }
      if (content is! String) {
        throw const FormatException('Library package file content must be text.');
      }
      files.add(
        WorkshopReusableModuleFile(
          sourcePath: sourcePath,
          targetPath: targetPath,
          content: content,
        ),
      );
    }
    files.sort((left, right) => left.targetPath.compareTo(right.targetPath));

    final requirements = <WorkshopAssemblyRequirement>[];
    final rawRequirements = package['requirements'];
    if (rawRequirements is! List) {
      throw const FormatException('Library package requirements must be an array.');
    }
    final seenRequirements = <String>{};
    for (final raw in rawRequirements) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Library package requirement must be an object.');
      }
      final kind = _requirementKind(raw['kind']?.toString() ?? '');
      final description = raw['description']?.toString().trim() ?? '';
      if (description.isEmpty) {
        throw const FormatException('Library package requirement description is empty.');
      }
      final required = raw['required'];
      if (required is! bool) {
        throw const FormatException('Library package requirement flag is invalid.');
      }
      final requirement = WorkshopAssemblyRequirement(
        kind: kind,
        description: description,
        required: required,
      );
      if (!seenRequirements.add(requirement.stableKey)) {
        throw const FormatException('Library package contains duplicate requirements.');
      }
      requirements.add(requirement);
    }
    requirements.sort((left, right) => left.stableKey.compareTo(right.stableKey));

    return WorkshopReusableModulePackage(
      assetId: assetId,
      version: version,
      capabilities: List<String>.unmodifiable(capabilities),
      contracts: List<String>.unmodifiable(contracts),
      files: List<WorkshopReusableModuleFile>.unmodifiable(files),
      requirements: List<WorkshopAssemblyRequirement>.unmodifiable(requirements),
      availability: availability,
      manifestDigest: manifestSha,
      artifactDigest: moduleTreeSha,
    );
  }

  static WorkshopAssemblyRequirementKind _requirementKind(String raw) =>
      switch (raw.trim()) {
        'dependency' => WorkshopAssemblyRequirementKind.dependency,
        'configuration' => WorkshopAssemblyRequirementKind.configuration,
        'nativeConfiguration' =>
          WorkshopAssemblyRequirementKind.nativeConfiguration,
        'permission' => WorkshopAssemblyRequirementKind.permission,
        'secret' => WorkshopAssemblyRequirementKind.secret,
        'migration' => WorkshopAssemblyRequirementKind.migration,
        'manualReview' => WorkshopAssemblyRequirementKind.manualReview,
        _ => throw const FormatException(
            'Library package contains an unknown requirement kind.',
          ),
      };

  static List<String> _stringList(Object? raw, String field) {
    if (raw is! List) {
      throw FormatException('Library package $field must be an array.');
    }
    final values = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException('Library package $field contains an invalid value.');
      }
      final value = item.trim();
      if (!seen.add(value)) {
        throw FormatException('Library package $field contains duplicates.');
      }
      values.add(value);
    }
    values.sort();
    return values;
  }

  static bool _isSafePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('~') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.contains('\u0000')) {
      return false;
    }
    final segments = path.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return false;
    }
    final lower = segments.map((segment) => segment.toLowerCase()).toList();
    if (lower.any(
      (segment) => const <String>{
        '.git',
        '.dart_tool',
        '.gradle',
        'build',
        'node_modules',
      }.contains(segment),
    )) {
      return false;
    }
    final fileName = lower.last;
    if (fileName == '.env' ||
        fileName == 'key.properties' ||
        fileName == 'keystore.properties' ||
        fileName == 'local.properties' ||
        fileName.endsWith('.jks') ||
        fileName.endsWith('.keystore') ||
        fileName.endsWith('.p12') ||
        fileName.endsWith('.pfx') ||
        fileName.endsWith('.pem') ||
        fileName.endsWith('.key')) {
      return false;
    }
    return true;
  }

  static String _canonicalJson(Object? value) {
    final normalized = _canonicalize(value);
    return jsonEncode(normalized);
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('Library package contains a non-JSON value.');
  }
}
