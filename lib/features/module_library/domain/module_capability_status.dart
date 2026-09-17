enum ModuleCapabilityAvailability {
  complete,
  partial,
  researching,
  absent,
  researchUnavailable,
}

enum ModuleCertifiedAvailability {
  active,
  deprecated,
  revoked,
}

final class ModuleResearchSignal {
  const ModuleResearchSignal({
    required this.available,
    this.state,
    this.candidateCount = 0,
    this.qualifiedCandidates = 0,
    this.shortlisted = 0,
    this.submitted = 0,
    this.securityReview = 0,
    this.securityBlocked = 0,
    this.lastScan,
  });

  final bool available;
  final String? state;
  final int candidateCount;
  final int qualifiedCandidates;
  final int shortlisted;
  final int submitted;
  final int securityReview;
  final int securityBlocked;
  final DateTime? lastScan;

  bool get isActive {
    if (!available) return false;
    return const <String>{
      'SEARCHING',
      'SECURITY_REVIEW',
      'SUBMITTED',
      'CANDIDATES_FOUND',
    }.contains(state?.toUpperCase());
  }
}

final class ModuleCapabilityStatus {
  const ModuleCapabilityStatus({
    required this.capabilityId,
    required this.title,
    required this.desiredCandidates,
    required this.certifiedActive,
    required this.certifiedDeprecated,
    required this.revoked,
    required this.targets,
    required this.research,
    required this.availability,
    required this.certifiedPins,
  });

  final String capabilityId;
  final String title;
  final int desiredCandidates;
  final int certifiedActive;
  final int certifiedDeprecated;
  final int revoked;
  final List<String> targets;
  final ModuleResearchSignal research;
  final ModuleCapabilityAvailability availability;
  final List<String> certifiedPins;

  int get presentCount => certifiedActive;

  String get progressLabel => '$presentCount/$desiredCandidates';

  String get statusLabel => switch (availability) {
        ModuleCapabilityAvailability.complete => 'Completo $progressLabel',
        ModuleCapabilityAvailability.partial => 'Parziale $progressLabel',
        ModuleCapabilityAvailability.researching => 'In ricerca $progressLabel',
        ModuleCapabilityAvailability.absent => 'Assente $progressLabel',
        ModuleCapabilityAvailability.researchUnavailable =>
          'Ricerca non disponibile $progressLabel',
      };

  bool get canReuse => certifiedActive > 0;
}

/// Deterministic, transport-neutral projection for the V1 Modules dashboard.
///
/// The Module Library catalog is the *only* authority for reusable certified
/// modules. Researcher data can explain progress toward missing coverage but it
/// can never increase [certifiedActive] or make [canReuse] true.
abstract final class ModuleCapabilityStatusProjector {
  static List<ModuleCapabilityStatus> project({
    required Map<String, Object?> needsJson,
    required Map<String, Object?> catalogJson,
    Map<String, Object?>? researcherJson,
  }) {
    final needs = _mapList(needsJson['items'], field: 'needs.items');
    final catalog = _mapList(catalogJson['assets'], field: 'catalog.assets');
    final researcherRows = researcherJson == null
        ? const <Map<String, Object?>>[]
        : _mapList(
            researcherJson['capabilities'],
            field: 'researcher.capabilities',
          );

    final researchByCapability = <String, Map<String, Object?>>{
      for (final row in researcherRows)
        if (_string(row['capability_id']).isNotEmpty)
          _string(row['capability_id']): row,
    };

    final result = <ModuleCapabilityStatus>[];
    final seenNeeds = <String>{};

    for (final need in needs) {
      final capabilityId = _string(need['capability_id']);
      if (capabilityId.isEmpty || !seenNeeds.add(capabilityId)) {
        throw const FormatException(
          'Module Library needs contain an empty or duplicate capability id.',
        );
      }
      final desired = _positiveInt(need['desired_candidates']);
      final title = _string(need['title']);
      final targets = _stringList(need['targets']);
      if (title.isEmpty || targets.isEmpty) {
        throw FormatException('Incomplete Module Library need: $capabilityId.');
      }

      var active = 0;
      var deprecated = 0;
      var revoked = 0;
      final pins = <String>[];
      for (final asset in catalog) {
        final capabilities = _stringList(asset['capabilities']);
        if (!capabilities.contains(capabilityId)) continue;
        if (_string(asset['status']).toLowerCase() != 'certified') continue;

        final id = _string(asset['id']);
        final version = _string(asset['version']);
        if (id.isEmpty || version.isEmpty) {
          throw FormatException(
            'Certified Module Library asset for $capabilityId has no pin.',
          );
        }

        switch (_string(asset['availability']).toLowerCase()) {
          case 'revoked':
            revoked += 1;
          case 'deprecated':
            deprecated += 1;
          case '':
          case 'active':
            active += 1;
            pins.add('$id@$version');
          default:
            throw FormatException(
              'Invalid Module Library availability for $id@$version.',
            );
        }
      }
      pins.sort();

      final researcher = researchByCapability[capabilityId];
      final research = researcher == null
          ? ModuleResearchSignal(available: researcherJson != null)
          : ModuleResearchSignal(
              available: true,
              state: _nullableString(researcher['research_state']),
              candidateCount: _nonNegativeInt(researcher['candidate_count']),
              qualifiedCandidates:
                  _nonNegativeInt(researcher['qualified_candidates']),
              shortlisted: _nonNegativeInt(researcher['shortlisted']),
              submitted: _nonNegativeInt(researcher['submitted']),
              securityReview:
                  _nonNegativeInt(researcher['security_review']),
              securityBlocked:
                  _nonNegativeInt(researcher['security_blocked']),
              lastScan: _date(researcher['last_scan']),
            );

      final availability = active >= desired
          ? ModuleCapabilityAvailability.complete
          : active > 0
              ? ModuleCapabilityAvailability.partial
              : research.isActive
                  ? ModuleCapabilityAvailability.researching
                  : research.available
                      ? ModuleCapabilityAvailability.absent
                      : ModuleCapabilityAvailability.researchUnavailable;

      result.add(
        ModuleCapabilityStatus(
          capabilityId: capabilityId,
          title: title,
          desiredCandidates: desired,
          certifiedActive: active,
          certifiedDeprecated: deprecated,
          revoked: revoked,
          targets: List<String>.unmodifiable(targets),
          research: research,
          availability: availability,
          certifiedPins: List<String>.unmodifiable(pins),
        ),
      );
    }

    // Certified catalog assets remain visible even if their capability is not
    // pre-declared in needs.json. Needs are coverage goals, not a display allowlist.
    final catalogOnlyCapabilities = <String>{};
    for (final asset in catalog) {
      if (_string(asset['status']).toLowerCase() != 'certified') continue;
      for (final capabilityId in _stringList(asset['capabilities'])) {
        if (!seenNeeds.contains(capabilityId)) catalogOnlyCapabilities.add(capabilityId);
      }
    }
    for (final capabilityId in catalogOnlyCapabilities) {
      var active = 0;
      var deprecated = 0;
      var revoked = 0;
      final pins = <String>[];
      final targets = <String>{};
      for (final asset in catalog) {
        if (_string(asset['status']).toLowerCase() != 'certified' ||
            !_stringList(asset['capabilities']).contains(capabilityId)) continue;
        targets.addAll(_stringList(asset['platforms']));
        final id = _string(asset['id']);
        final version = _string(asset['version']);
        if (id.isEmpty || version.isEmpty) {
          throw FormatException('Certified Module Library asset for $capabilityId has no pin.');
        }
        switch (_string(asset['availability']).toLowerCase()) {
          case 'revoked': revoked += 1;
          case 'deprecated': deprecated += 1;
          case '':
          case 'active': active += 1; pins.add('$id@$version');
          default: throw FormatException('Invalid Module Library availability for $id@$version.');
        }
      }
      pins.sort();
      final sortedTargets = targets.toList()..sort();
      result.add(ModuleCapabilityStatus(
        capabilityId: capabilityId,
        title: capabilityId,
        desiredCandidates: 1,
        certifiedActive: active,
        certifiedDeprecated: deprecated,
        revoked: revoked,
        targets: List<String>.unmodifiable(sortedTargets),
        research: ModuleResearchSignal(available: researcherJson != null),
        availability: active > 0 ? ModuleCapabilityAvailability.complete : ModuleCapabilityAvailability.absent,
        certifiedPins: List<String>.unmodifiable(pins),
      ));
    }

    result.sort((left, right) => left.capabilityId.compareTo(right.capabilityId));
    return List<ModuleCapabilityStatus>.unmodifiable(result);
  }

  static List<Map<String, Object?>> _mapList(
    Object? raw, {
    required String field,
  }) {
    if (raw is! List) throw FormatException('$field must be an array.');
    return raw.map((item) {
      if (item is! Map) throw FormatException('$field entries must be objects.');
      return Map<String, Object?>.from(item);
    }).toList(growable: false);
  }

  static String _string(Object? value) => value?.toString().trim() ?? '';

  static String? _nullableString(Object? value) {
    final result = _string(value);
    return result.isEmpty ? null : result;
  }

  static int _positiveInt(Object? value) {
    final result = value is int ? value : int.tryParse(_string(value));
    if (result == null || result < 1) {
      throw const FormatException('Expected a positive integer.');
    }
    return result;
  }

  static int _nonNegativeInt(Object? value) {
    if (value == null) return 0;
    final result = value is int ? value : int.tryParse(_string(value));
    if (result == null || result < 0) {
      throw const FormatException('Expected a non-negative integer.');
    }
    return result;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    final result = raw
        .map(_string)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();
    return result;
  }

  static DateTime? _date(Object? raw) {
    final value = _nullableString(raw);
    return value == null ? null : DateTime.tryParse(value)?.toUtc();
  }
}
