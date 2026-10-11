import 'dart:convert';

enum AivexusProjectKind { software, cad, game }

/// Canonical JSON for revision/idempotency comparisons; never contains binaries.
String aivexusCanonicalJson(Object? value) {
  Object? sorted(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return <String, Object?>{for (final key in keys) key: sorted(item[key])};
    }
    if (item is List) return item.map(sorted).toList();
    return item;
  }

  return jsonEncode(sorted(value));
}

/// Additive ProjectExtension v1. Unknown/invalid versions remain losslessly
/// readable, but cannot be edited by a client that does not understand them.
final class AivexusProjectExtension {
  AivexusProjectExtension._(this._encoded, this.readOnlyReason);

  factory AivexusProjectExtension.read(Object? value) {
    final encoded = jsonEncode(value);
    String? reason;
    try {
      _validate(value);
    } on FormatException catch (error) {
      reason = error.message;
    }
    return AivexusProjectExtension._(encoded, reason);
  }

  factory AivexusProjectExtension.validated(Map<String, Object?> value) {
    final extension = AivexusProjectExtension.read(value);
    if (extension.isReadOnly) throw FormatException(extension.readOnlyReason!);
    return extension;
  }

  factory AivexusProjectExtension.draft(AivexusProjectKind kind) {
    return AivexusProjectExtension.validated(<String, Object?>{
      'schemaVersion': 1,
      'projectKind': kind.name,
      'specRevision': 1,
      'domainSpec': switch (kind) {
        AivexusProjectKind.software => <String, Object?>{},
        AivexusProjectKind.cad => <String, Object?>{
          'inputMode': 'description',
          'units': 'mm',
          'representation': 'parametric_solid',
          'parameters': <String, Object?>{},
          'measurements': <Object?>[],
          'printerProfileRef': null,
        },
        AivexusProjectKind.game => <String, Object?>{
          'dimension': '2d',
          'targetPlatforms': <String>['web'],
          'engine': <String, Object?>{'name': 'Godot', 'version': null},
          'templateId': null,
          'rules': <String, Object?>{},
          'controls': <String>['touch', 'keyboard'],
        },
      },
      'inputs': <Object?>[],
      'requestedOutputs': switch (kind) {
        AivexusProjectKind.cad => <String>['STEP', 'STL', '3MF'],
        AivexusProjectKind.game => <String>['source', 'web'],
        AivexusProjectKind.software => <String>[],
      },
      'artifacts': <Object?>[],
      'validationRefs': <String>[],
    });
  }

  final String _encoded;
  final String? readOnlyReason;
  bool get isReadOnly => readOnlyReason != null;
  Object? toJson() => jsonDecode(_encoded);
  Map<String, dynamic> get _data {
    final data = toJson();
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  AivexusProjectKind? get kind {
    for (final kind in AivexusProjectKind.values) {
      if (_data['projectKind'] == kind.name) return kind;
    }
    return null;
  }

  int? get specRevision =>
      _data['specRevision'] is int ? _data['specRevision'] as int : null;

  Map<String, dynamic> get domainSpec =>
      Map<String, dynamic>.from(_data['domainSpec'] as Map);

  /// Old outputs remain in history, explicitly tied to their source revision.
  List<Map<String, dynamic>> get currentArtifacts =>
      (_data['artifacts'] as List? ?? const <Object?>[])
          .whereType<Map<String, dynamic>>()
          .where((item) => item['sourceSpecRevision'] == specRevision)
          .toList(growable: false);

  AivexusProjectExtension revise({
    Map<String, Object?>? domainSpec,
    List<Map<String, Object?>>? inputs,
    List<String>? requestedOutputs,
  }) {
    if (isReadOnly) throw StateError(readOnlyReason!);
    final data = _data;
    final next = <String, Object?>{
      ...data,
      if (domainSpec != null) 'domainSpec': domainSpec,
      if (inputs != null) 'inputs': inputs,
      if (requestedOutputs != null) 'requestedOutputs': requestedOutputs,
    };
    if (aivexusCanonicalJson(next) == aivexusCanonicalJson(data)) return this;
    next['specRevision'] = specRevision! + 1;
    return AivexusProjectExtension.validated(next);
  }

  static void _validate(Object? value) {
    final root = aivexusObject(value, const <String>[
      'schemaVersion',
      'projectKind',
      'specRevision',
      'domainSpec',
      'inputs',
      'requestedOutputs',
      'artifacts',
      'validationRefs',
    ]);
    aivexusRequire(root['schemaVersion'] == 1, 'Unsupported schemaVersion');
    _choice(root['projectKind'], const ['software', 'cad', 'game']);
    _positiveInt(root['specRevision']);
    aivexusRequire(root['domainSpec'] is Map<String, dynamic>, 'domainSpec');
    _strings(root['requestedOutputs']);
    _strings(root['validationRefs']);
    aivexusRequire(root['inputs'] is List, 'inputs');
    for (final raw in root['inputs'] as List) {
      validateAivexusInput(raw);
    }
    aivexusRequire(root['artifacts'] is List, 'artifacts');
    for (final raw in root['artifacts'] as List) {
      final artifact = aivexusObject(raw, const [
        'ref',
        'name',
        'role',
        'format',
        'mimeType',
        'sizeBytes',
        'sha256',
        'sourceSpecRevision',
        'geometryType',
        'units',
        'generator',
      ]);
      for (final key in ['ref', 'name', 'format', 'mimeType']) {
        _text(artifact[key]);
      }
      _choice(artifact['role'], const [
        'source',
        'cad',
        'mesh',
        'drawing',
        'preview',
        'build',
        'manifest',
        'report',
        'machine_code',
      ]);
      _positiveInt(artifact['sizeBytes']);
      _hash(artifact['sha256']);
      _positiveInt(artifact['sourceSpecRevision']);
      aivexusRequire(
        (artifact['sourceSpecRevision'] as int) <=
            (root['specRevision'] as int),
        'Artifact revision is newer than specification',
      );
      _choice(artifact['geometryType'], const [
        'parametric_solid',
        'brep',
        'mesh',
        'sketch',
        'none',
      ]);
      if (artifact['units'] != null) _units(artifact['units']);
      final generator = aivexusObject(artifact['generator'], const [
        'name',
        'version',
        'jobRef',
      ]);
      for (final value in generator.values) {
        _text(value);
      }
    }

    final spec = root['domainSpec'];
    if (root['projectKind'] == 'cad') {
      final cad = aivexusObject(spec, const [
        'inputMode',
        'units',
        'representation',
        'parameters',
        'measurements',
        'printerProfileRef',
      ]);
      _choice(cad['inputMode'], const [
        'description',
        'photo_reference',
        'photo_relief',
        'single_photo_reconstruction',
        'multi_photo',
        'model_import',
      ]);
      _units(cad['units']);
      _choice(cad['representation'], const ['parametric_solid', 'mesh']);
      aivexusRequire(cad['parameters'] is Map, 'parameters');
      if (cad['printerProfileRef'] != null) _text(cad['printerProfileRef']);
      aivexusRequire(cad['measurements'] is List, 'measurements');
      for (final raw in cad['measurements'] as List) {
        final measure = aivexusObject(raw, const [
          'name',
          'value',
          'unit',
          'source',
          'confirmed',
        ]);
        _text(measure['name']);
        aivexusRequire(measure['value'] is num, 'measurement value');
        _units(measure['unit']);
        _choice(measure['source'], const ['user', 'derived', 'estimated']);
        aivexusRequire(measure['confirmed'] is bool, 'confirmed');
      }
      if (const [
        'photo_reference',
        'photo_relief',
        'single_photo_reconstruction',
        'multi_photo',
      ].contains(cad['inputMode'])) {
        aivexusRequire(
          (root['inputs'] as List).any(
            (input) => (input as Map)['role'] == 'photo',
          ),
          'Photographic modes require a photo input',
        );
      }
    } else if (root['projectKind'] == 'game') {
      final game = aivexusObject(spec, const [
        'dimension',
        'targetPlatforms',
        'engine',
        'templateId',
        'rules',
        'controls',
      ]);
      _choice(game['dimension'], const ['2d', '3d']);
      _strings(game['targetPlatforms'], nonEmpty: true);
      for (final platform in game['targetPlatforms'] as List) {
        _choice(platform, const [
          'web',
          'android',
          'windows',
          'macos',
          'linux',
          'ios',
        ]);
      }
      final engine = aivexusObject(game['engine'], const ['name', 'version']);
      _text(engine['name']);
      if (engine['version'] != null) _text(engine['version']);
      if (game['templateId'] != null) _text(game['templateId']);
      aivexusRequire(game['rules'] is Map, 'rules');
      _strings(game['controls'], nonEmpty: true);
      for (final control in game['controls'] as List) {
        _choice(control, const ['touch', 'keyboard', 'mouse', 'gamepad']);
      }
    }
  }
}

void aivexusRequire(bool valid, String field) {
  if (!valid) throw FormatException('Invalid Aivexus value: $field');
}

Map<String, dynamic> aivexusObject(Object? value, List<String> keys) {
  aivexusRequire(value is Map, 'object');
  final map = Map<String, dynamic>.from(value! as Map);
  aivexusRequire(
    map.length == keys.length && keys.every(map.containsKey),
    'required/unknown object fields',
  );
  return map;
}

void validateAivexusInput(Object? value) {
  final input = aivexusObject(value, const [
    'ref',
    'name',
    'role',
    'mimeType',
    'sizeBytes',
    'sha256',
  ]);
  for (final key in ['ref', 'name', 'mimeType']) {
    _text(input[key]);
  }
  _choice(input['role'], const [
    'photo',
    'drawing',
    'model',
    'texture',
    'audio',
    'other',
  ]);
  _positiveInt(input['sizeBytes']);
  _hash(input['sha256']);
}

void _text(Object? value) => aivexusRequire(
  value is String && value.trim().isNotEmpty,
  'non-empty text',
);
void _positiveInt(Object? value) =>
    aivexusRequire(value is int && value > 0, 'positive integer');
void _hash(Object? value) => aivexusRequire(
  value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
  'sha256',
);
void _choice(Object? value, List<String> values) =>
    aivexusRequire(values.contains(value), 'enum: $value');
void _units(Object? value) => _choice(value, const ['mm', 'cm', 'm', 'inch']);
void _strings(Object? value, {bool nonEmpty = false}) {
  aivexusRequire(value is List, 'list');
  final items = value! as List;
  aivexusRequire(!nonEmpty || items.isNotEmpty, 'non-empty list');
  aivexusRequire(items.toSet().length == items.length, 'unique list');
  for (final item in items) {
    _text(item);
  }
}
