# Linux Workshop readiness

AI Orchestrator must not advertise a Linux target as `offlineLocal` merely because the Flutter executable is present.

## Readiness contract

A generic Flutter Linux build requires all of the following to be verified on the current host:

- Flutter and Dart are executable;
- the host is Linux;
- `clang` is executable;
- `cmake` is executable;
- `ninja` is executable;
- `pkg-config` is executable;
- `pkg-config --exists gtk+-3.0` succeeds.

`WorkshopLinuxBuildHostProbe` is the authority for the native Linux portion of this contract. It is read-only: it never installs packages, downloads SDKs, changes repositories, or escalates privileges.

## State semantics

- `available` + `offlineLocal`: the generic Linux build host is verified and Cantiere may attempt a local Linux build.
- `incomplete`: the current host is Linux, but one or more native prerequisites are missing. `missingComponents` identifies the exact generic prerequisite.
- `unavailable`: the current host is not Linux, or Flutter/Dart cannot provide the target.

Project-specific native plugin requirements are intentionally outside the generic probe. They must be reported by the concrete build attempt/diagnostics rather than guessed globally.

## Why this is fail-closed

A false positive is more damaging than a conservative unavailable state: Cantiere could otherwise accept an offline build request, do substantial planning and generation work, and fail only at the final native compile step. The readiness gate therefore promotes Linux to `offlineLocal` only after the generic host prerequisites are proven.

## Future evolution

A later LocalToolchainManager may offer an explicit, user-approved installation/remediation flow. That manager must remain separate from the detector so inspection itself stays deterministic, safe, and usable without network access.
