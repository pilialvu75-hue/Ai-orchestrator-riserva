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


## Test coverage and evidence boundary

The local Python test suite includes real STEP/STL/3MF round trips for
specification revisions 1 (4 mm) and 2 (5 mm), plus an intentionally damaged
STL that **must** fail mesh validation. Run the Python tests in a separately
provisioned CAD toolchain:

    python -m unittest discover -p test_cad1.py -v

The existing six GitHub Flutter/platform workflows do **not** install and
execute this Python/CadQuery test suite. Their PASS is not evidence of
CadQuery export correctness, of binary artifact persistence, or of a connected
runner. Record the toolchain version and generated output SHA-256 from the
actual runtime whenever claiming such evidence.

Cantiere's shared attachment store and ResourceExchange integration remain
outside this domain-only PR. Do not put local sample hashes in shared project
state without storing and verifying the corresponding immutable bytes.


## Fail-closed local receipts

`validate_plate.py` now records `status=PASS` only after all five
geometric/format checks succeed. A failed STEP round-trip, STL/3MF mesh or
3MF-unit check returns `status=FAIL`, preserves per-check diagnostic errors
and **emits an empty `artifacts` list**. The CLI exits with a failure code.
The Python suite tests both successful SHA-256 receipts and corrupt-STL
rejection. UNKNOWN Fusion/print/Cantiere/Diagnostics checks remain UNKNOWN.

These are **local-only** receipts (`notCanonicalEvidence=true`), not
immutable Cantiere artifact references. The output bytes must first be
stored and verified through the authorized Cantiere attachment interface;
only then may the shared ProjectExtension/ResourceExchange record
`ref`, revision and provenance. Never treat an unpersisted local file
path or its SHA-256 as proof that downstream consumers can retrieve it.
