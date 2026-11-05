import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/domains/cad/cad1_domain_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';

void main() {
  test('sample preserves measured geometry and expected volume', () {
    final plate = Cad1MeasuredPlate.sample;
    expect(plate.lengthMm, 60);
    expect(plate.widthMm, 40);
    expect(plate.thicknessMm, 4);
    expect(plate.holes.map((h) => h.diameterMm), <double>[5, 5]);
    expect(plate.expectedVolumeMm3, closeTo(9600 - 50 * math.pi, 1e-8));
  });

  test('consumes the Cantiere CAD ProjectExtension and increments revision', () {
    final draft = AivexusProjectExtension.draft(AivexusProjectKind.cad);
    final plate = Cad1MeasuredPlate.sample;
    final revised = plate.revise(draft);
    expect(revised.specRevision, 2);
    expect(revised.kind, AivexusProjectKind.cad);
    final loaded = Cad1MeasuredPlate.fromExtension(revised);
    expect(loaded.expectedVolumeMm3, closeTo(plate.expectedVolumeMm3, 1e-8));

    final unchanged = plate.revise(revised);
    expect(unchanged.specRevision, 2);
  });

  test('rejects unsupported non-CAD extension', () {
    final other = AivexusProjectExtension.draft(AivexusProjectKind.game);
    expect(
      () => Cad1MeasuredPlate.fromExtension(other),
      throwsFormatException,
    );
  });

  test('rejects overlapping holes and invalid measurements', () {
    expect(
      () => Cad1MeasuredPlate(
        lengthMm: 60,
        widthMm: 40,
        thicknessMm: 4,
        holes: <Cad1Hole>[
          const Cad1Hole(15, 20, 5),
          const Cad1Hole(16, 20, 5),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => Cad1MeasuredPlate(
        lengthMm: double.nan,
        widthMm: 40,
        thicknessMm: 4,
        holes: <Cad1Hole>[
          const Cad1Hole(15, 20, 5),
          const Cad1Hole(45, 20, 5),
        ],
      ),
      throwsFormatException,
    );
  });
}
