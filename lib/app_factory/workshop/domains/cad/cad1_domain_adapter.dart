import 'dart:math' as math;

import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';

/// Bounded CAD-1 domain interpretation of the Cantiere-owned extension.
/// This class does not run native code or manage projects, storage or jobs.
final class Cad1Hole {
  const Cad1Hole(this.xMm, this.yMm, this.diameterMm);

  final double xMm;
  final double yMm;
  final double diameterMm;

  Map<String, Object?> toJson() => <String, Object?>{
    'centerXMm': xMm,
    'centerYMm': yMm,
    'diameterMm': diameterMm,
  };
}

final class Cad1MeasuredPlate {
  Cad1MeasuredPlate({
    required this.lengthMm,
    required this.widthMm,
    required this.thicknessMm,
    required this.holes,
  }) {
    if (!_positive(lengthMm) || !_positive(widthMm) || !_positive(thicknessMm)) {
      throw const FormatException('CAD-1 dimensions must be positive and finite');
    }
    if (holes.length != 2) {
      throw const FormatException('CAD-1 requires two through-holes');
    }
    for (final hole in holes) {
      if (!_positive(hole.diameterMm) ||
          !hole.xMm.isFinite ||
          !hole.yMm.isFinite ||
          hole.xMm <= hole.diameterMm / 2 ||
          hole.xMm >= lengthMm - hole.diameterMm / 2 ||
          hole.yMm <= hole.diameterMm / 2 ||
          hole.yMm >= widthMm - hole.diameterMm / 2) {
        throw const FormatException('CAD-1 hole outside the plate');
      }
    }
    final dx = holes[0].xMm - holes[1].xMm;
    final dy = holes[0].yMm - holes[1].yMm;
    if (math.sqrt(dx * dx + dy * dy) <=
        (holes[0].diameterMm + holes[1].diameterMm) / 2) {
      throw const FormatException('CAD-1 holes overlap');
    }
  }

  final double lengthMm;
  final double widthMm;
  final double thicknessMm;
  final List<Cad1Hole> holes;

  static bool _positive(double value) => value.isFinite && value > 0;

  static const String capability = 'cad.parametric.build';

  static Cad1MeasuredPlate get sample => Cad1MeasuredPlate(
    lengthMm: 60,
    widthMm: 40,
    thicknessMm: 4,
    holes: <Cad1Hole>[
      const Cad1Hole(15, 20, 5),
      const Cad1Hole(45, 20, 5),
    ],
  );

  double get expectedVolumeMm3 =>
      thicknessMm *
      (lengthMm * widthMm -
          holes.fold<double>(
            0,
            (sum, hole) =>
                sum + math.pi * hole.diameterMm * hole.diameterMm / 4,
          ));

  Map<String, Object?> toDomainSpec() => <String, Object?>{
    'inputMode': 'description',
    'units': 'mm',
    'representation': 'parametric_solid',
    'parameters': <String, Object?>{
      'lengthMm': lengthMm,
      'widthMm': widthMm,
      'thicknessMm': thicknessMm,
      'holes': holes.map((hole) => hole.toJson()).toList(growable: false),
    },
    'measurements': <Object?>[],
    'printerProfileRef': null,
  };

  /// Revision increments through the existing shared Cantiere contract.
  AivexusProjectExtension revise(AivexusProjectExtension extension) {
    if (extension.kind != AivexusProjectKind.cad || extension.isReadOnly) {
      throw const FormatException('Expected editable CAD ProjectExtension');
    }
    return extension.revise(domainSpec: toDomainSpec());
  }

  factory Cad1MeasuredPlate.fromExtension(AivexusProjectExtension extension) {
    if (extension.isReadOnly || extension.kind != AivexusProjectKind.cad) {
      throw const FormatException('Expected valid CAD ProjectExtension v1');
    }
    final spec = extension.domainSpec;
    if (spec['inputMode'] != 'description' ||
        spec['units'] != 'mm' ||
        spec['representation'] != 'parametric_solid') {
      throw const FormatException('CAD-1 requires measured parametric input in mm');
    }
    final parameters = spec['parameters'];
    if (parameters is! Map) {
      throw const FormatException('Missing CAD parameters');
    }
    double measure(Object? value) {
      if (value is! num || !value.isFinite) {
        throw const FormatException('Invalid CAD measurement');
      }
      return value.toDouble();
    }

    final rawHoles = parameters['holes'];
    if (rawHoles is! List || rawHoles.length != 2) {
      throw const FormatException('Two bore measurements are required');
    }
    return Cad1MeasuredPlate(
      lengthMm: measure(parameters['lengthMm']),
      widthMm: measure(parameters['widthMm']),
      thicknessMm: measure(parameters['thicknessMm']),
      holes: rawHoles.map((raw) {
        if (raw is! Map) {
          throw const FormatException('Invalid CAD hole');
        }
        return Cad1Hole(
          measure(raw['centerXMm']),
          measure(raw['centerYMm']),
          measure(raw['diameterMm']),
        );
      }).toList(growable: false),
    );
  }
}
