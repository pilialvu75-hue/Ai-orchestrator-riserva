import 'dart:math' as math;

/// Kind of reusable production knowledge captured by the Workshop.
///
/// The library stores descriptors and references, not arbitrary executable
/// code. Concrete files remain owned by the project/artifact layer.
enum WorkshopReusableAssetKind {
  projectTemplate,
  module,
  component,
  architecturePattern,
}

/// Provenance of a reusable asset.
enum WorkshopReusableAssetOrigin {
  builtIn,
  completedProject,
  verifiedTask,
  imported,
}

/// A verified unit that may be reused before asking an AI provider to generate
/// the same solution again.
final class WorkshopReusableAsset {
  WorkshopReusableAsset({
    required this.id,
    required this.name,
    required this.kind,
    required this.origin,
    required this.description,
    this.sourceProjectId,
    this.sourceTaskId,
    this.target,
    this.artifactPath,
    this.tags = const <String>[],
    this.capabilities = const <String>[],
    this.entryPaths = const <String>[],
    this.validationScore = 1.0,
    this.reuseCount = 0,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  })  : assert(validationScore >= 0 && validationScore <= 1),
        createdAt = (createdAt ?? DateTime.now()).toUtc(),
        lastUsedAt = lastUsedAt?.toUtc();

  final String id;
  final String name;
  final WorkshopReusableAssetKind kind;
  final WorkshopReusableAssetOrigin origin;
  final String description;
  final String? sourceProjectId;
  final String? sourceTaskId;
  final String? target;
  final String? artifactPath;
  final List<String> tags;
  final List<String> capabilities;
  final List<String> entryPaths;
  final double validationScore;
  final int reuseCount;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  bool get isVerified => validationScore >= 0.8;

  WorkshopReusableAsset markUsed({DateTime? at}) {
    return WorkshopReusableAsset(
      id: id,
      name: name,
      kind: kind,
      origin: origin,
      description: description,
      sourceProjectId: sourceProjectId,
      sourceTaskId: sourceTaskId,
      target: target,
      artifactPath: artifactPath,
      tags: tags,
      capabilities: capabilities,
      entryPaths: entryPaths,
      validationScore: validationScore,
      reuseCount: reuseCount + 1,
      createdAt: createdAt,
      lastUsedAt: (at ?? DateTime.now()).toUtc(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.name,
        'origin': origin.name,
        'description': description,
        'sourceProjectId': sourceProjectId,
        'sourceTaskId': sourceTaskId,
        'target': target,
        'artifactPath': artifactPath,
        'tags': tags,
        'capabilities': capabilities,
        'entryPaths': entryPaths,
        'validationScore': validationScore,
        'reuseCount': reuseCount,
        'createdAt': createdAt.toIso8601String(),
        'lastUsedAt': lastUsedAt?.toIso8601String(),
      };

  factory WorkshopReusableAsset.fromJson(Map<String, dynamic> json) {
    return WorkshopReusableAsset(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      kind: _enumByName(
        WorkshopReusableAssetKind.values,
        _requiredString(json, 'kind'),
        'kind',
      ),
      origin: _enumByName(
        WorkshopReusableAssetOrigin.values,
        _requiredString(json, 'origin'),
        'origin',
      ),
      description: _requiredString(json, 'description'),
      sourceProjectId: _optionalString(json['sourceProjectId']),
      sourceTaskId: _optionalString(json['sourceTaskId']),
      target: _optionalString(json['target']),
      artifactPath: _optionalString(json['artifactPath']),
      tags: _stringList(json['tags']),
      capabilities: _stringList(json['capabilities']),
      entryPaths: _stringList(json['entryPaths']),
      validationScore: json['validationScore'] is num
          ? (json['validationScore'] as num)
              .toDouble()
              .clamp(0.0, 1.0)
              .toDouble()
          : 1.0,
      reuseCount: json['reuseCount'] is num
          ? math.max(0, (json['reuseCount'] as num).toInt())
          : 0,
      createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
      lastUsedAt: _date(json['lastUsedAt']),
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = _optionalString(json[key]);
    if (value == null) {
      throw FormatException('Reusable asset $key is missing.');
    }
    return value;
  }

  static String? _optionalString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return List<String>.unmodifiable(
      value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty),
    );
  }

  static DateTime? _date(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  static T _enumByName<T extends Enum>(
    Iterable<T> values,
    String name,
    String field,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown reusable asset $field: $name');
  }
}

/// A ranked local reuse candidate.
final class WorkshopReuseMatch {
  const WorkshopReuseMatch({
    required this.asset,
    required this.score,
    required this.reasons,
  });

  final WorkshopReusableAsset asset;
  final double score;
  final List<String> reasons;
}

/// In-memory, serializable index of verified reusable production knowledge.
///
/// The contract is deliberately independent from SQLite/Isar so persistence
/// can be added later without changing planner/executor callers.
final class WorkshopReuseLibrary {
  WorkshopReuseLibrary({
    Iterable<WorkshopReusableAsset> initialAssets =
        const <WorkshopReusableAsset>[],
  }) {
    for (final asset in initialAssets) {
      register(asset);
    }
  }

  final Map<String, WorkshopReusableAsset> _assets =
      <String, WorkshopReusableAsset>{};

  List<WorkshopReusableAsset> get assets =>
      List<WorkshopReusableAsset>.unmodifiable(_assets.values);

  int get length => _assets.length;

  void register(WorkshopReusableAsset asset) {
    final id = asset.id.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(asset.id, 'asset.id', 'Cannot be empty.');
    }
    _assets[id] = asset;
  }

  WorkshopReusableAsset? findById(String id) => _assets[id.trim()];

  bool remove(String id) => _assets.remove(id.trim()) != null;

  void markUsed(String id, {DateTime? at}) {
    final asset = findById(id);
    if (asset == null) return;
    _assets[asset.id] = asset.markUsed(at: at);
  }

  List<WorkshopReuseMatch> search({
    required String objective,
    List<String> requiredCapabilities = const <String>[],
    String? target,
    int limit = 5,
    bool verifiedOnly = true,
  }) {
    if (limit <= 0) return const <WorkshopReuseMatch>[];

    final objectiveTokens = _tokens(objective);
    final required = requiredCapabilities.expand(_tokens).toSet();
    final normalizedTarget = target?.trim().toLowerCase();
    final matches = <WorkshopReuseMatch>[];

    for (final asset in _assets.values) {
      if (verifiedOnly && !asset.isVerified) continue;

      final reasons = <String>[];
      var score = asset.validationScore * 0.35;

      final searchable = _tokens(
        '${asset.name} ${asset.description} ${asset.tags.join(' ')} '
        '${asset.capabilities.join(' ')}',
      );

      final objectiveOverlap = _overlapRatio(objectiveTokens, searchable);
      if (objectiveOverlap > 0) {
        score += objectiveOverlap * 0.35;
        reasons.add('objective-match');
      }

      if (required.isNotEmpty) {
        final capabilityTokens = asset.capabilities.expand(_tokens).toSet();
        final capabilityOverlap = _overlapRatio(required, capabilityTokens);
        if (capabilityOverlap > 0) {
          score += capabilityOverlap * 0.2;
          reasons.add('capability-match');
        }
      }

      if (normalizedTarget != null && normalizedTarget.isNotEmpty) {
        final assetTarget = asset.target?.trim().toLowerCase();
        if (assetTarget == normalizedTarget) {
          score += 0.1;
          reasons.add('target-match');
        }
      }

      if (asset.reuseCount > 0) {
        score += math.min(0.05, asset.reuseCount * 0.01);
        reasons.add('proven-reuse');
      }

      final boundedScore = score.clamp(0.0, 1.0).toDouble();
      if (boundedScore <= 0.35) continue;

      matches.add(
        WorkshopReuseMatch(
          asset: asset,
          score: boundedScore,
          reasons: List<String>.unmodifiable(reasons),
        ),
      );
    }

    matches.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return b.asset.validationScore.compareTo(a.asset.validationScore);
    });

    return List<WorkshopReuseMatch>.unmodifiable(matches.take(limit));
  }

  Map<String, dynamic> diagnostics() => <String, dynamic>{
        'assetCount': length,
        'verifiedCount': _assets.values.where((asset) => asset.isVerified).length,
        'reusedCount': _assets.values.where((asset) => asset.reuseCount > 0).length,
        'kinds': <String, int>{
          for (final kind in WorkshopReusableAssetKind.values)
            kind.name: _assets.values.where((asset) => asset.kind == kind).length,
        },
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'assets': _assets.values.map((asset) => asset.toJson()).toList(),
      };

  factory WorkshopReuseLibrary.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['assets'] is! List) {
      return WorkshopReuseLibrary();
    }

    final assets = <WorkshopReusableAsset>[];
    for (final raw in json['assets'] as List) {
      if (raw is! Map) continue;
      try {
        assets.add(
          WorkshopReusableAsset.fromJson(
            Map<String, dynamic>.from(raw),
          ),
        );
      } catch (_) {
        // One corrupt descriptor must not make the whole local library unusable.
      }
    }
    return WorkshopReuseLibrary(initialAssets: assets);
  }

  static Set<String> _tokens(String value) {
    return value
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.length > 1)
        .toSet();
  }

  static double _overlapRatio(Set<String> required, Set<String> available) {
    if (required.isEmpty || available.isEmpty) return 0;
    final common = required.intersection(available).length;
    return common / required.length;
  }
}
