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


## STL/3MF bore-position regression gate

A watertight plate with both bores shifted inward can have the **same**
volume, bounding box and triangle count as the requested shape; these
properties alone are insufficient to verify measured geometry. The validator
now inspects cross-sections at 10%, 50% and 90% thickness and requires an
exterior rectangular loop plus exactly two round bore contours matching
the CAD input's center positions and diameters within stated meshing
tolerances. This is a bounded check for the CAD-1 plate, not a general
3D mesh shape-comparison engine.

The dedicated Python CI rejects deliberately shifted-hole STL and 3MF
examples and verifies three successful cross-sections in legitimate output.
It must pass on the **exact current PR head** before reporting this fix as
validated. Fusion 360, physical printing, the secure execution runner and
persistent project attachment refs remain separate evidence gates.


## Downloadable, versioned external-test specimens (GitHub Actions)

The dedicated `Aivexus CAD-1 Domain Tests` GitHub Actions workflow
produces two **validated specimen directories**, one for `specRevision=1`
(thickness 4 mm) and another for `specRevision=2` (thickness 5 mm).
On a fully successful run it uploads a short-lived artifact called
`cad1-validated-samples-<commit SHA>` containing in **each** revision
directory:

- `extension.json`: exact input specification whose SHA-256 matches
  the receipt `inputSha256`;
- `plate.step`, `plate.stl`, `plate.3mf`: actual exported geometries;
- `receipt.json`: the five local CAD checks, model revision, actual
  sizes and SHA-256 hashes of each corresponding output.

Before upload, CI fails if any receipt did not pass, if a stored source or
output hash does not match its exact file bytes, if expected formats are
missing, or if the revision number is wrong. These artifacts expire after
14 days. They are **external-test samples only**: open STEP in Fusion 360
and STL/3MF in an independent slicer, and record the actual observations
before promoting any target-runtime or physical-print gate. Do not assume
that uploading validated samples implies Fusion import, print, printer
compatibility, or a deployed Cantiere CAD runner.

GitHub Actions storage is **not** ProjectExtension persistent storage:
it provides no immutable Cantiere `ref`, no verified ResourceExchange,
and no operational browser CAD capability. Library issue #113 remains
the integration/certification dependency.
