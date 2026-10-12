# CAD-1 — Measured parametric plate (domain-only)

This is the first CAD/3D domain fixture. It consumes Aivexus ProjectExtension v1's CAD domainSpec shape but does **not** implement Cantiere lifecycle, common persistence, Web navigation, a browser Python runtime, or a privileged worker. Do not execute generated code with repository credentials. The target runner must be isolated and capability-gated.

Requires Python, CadQuery 2.8.0 (with OCP), and trimesh. In this directory:

    python parametric_plate.py fixtures/plate_spec.json --out /tmp/cad1-out
    python validate_plate.py fixtures/plate_spec.json --exports /tmp/cad1-out --report /tmp/cad1-report.json
    python -m unittest discover -p test_cad1.py -v

Example: 60 x 40 x 4 mm plate; two diameter 5 mm through-holes centered at (15,20) and (45,20) mm. Change parameters and increment specRevision to produce a new, immutable artifact revision. Valid outputs: STEP (BREP), STL and 3MF (meshes). The validator checks through-hole geometry, STEP round-trip in OCP, positive closed meshes, size/volume and explicit 3MF mm units.

Generate a new receipt from the actual files each time. STEP exports contain a creation timestamp; 3MF contains timestamp metadata and ZIP timestamps, therefore SHA-256 can change even with unchanged geometry. Do not predict an artifact hash from spec alone. Cantiere must persist the exact output bytes and hash before creating an artifact ref or publishing a ResourceExchange result. Avoid fabricated availability or print success.

Only local build, file geometry and export validation can be claimed by this fixture. Real Fusion opening, physical printing, Cantiere runner integration, browser/device behavior and remote Diagnostics require independent evidence. Absent a CAD runner, surface capability unavailable with a recoverable project draft. A successful local fixture is not a deployed Studio 3D.

Bounded source under tools/aivexus/cad and lib/app_factory/workshop/domains/cad only. Shared Aivexus ProjectExtension, attachment store, ResourceExchange, project hub and workflow files are Cantiere-owned.
