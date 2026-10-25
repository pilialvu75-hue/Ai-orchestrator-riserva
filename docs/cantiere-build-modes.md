# Cantiere: local, online and hybrid builds

Owner clarification, 25 October 2026. This refines
[`ROADMAP_EVOLUTIVA.md`](ROADMAP_EVOLUTIVA.md), especially P9 and Build Lab.

The Cantiere is an application factory. It must manage compilation from its
own interface, including toolchain preparation, validation, errors, bounded
repair, artifacts and subsequent edits. A user must not need an external IDE
or manually operated build application. Compilers, SDKs and build engines are
implementation components, with platform-specific packaging and licensing.
Installing development tools on a test machine alone does not meet this goal.

## Required execution paths

| Path | Required behavior | Acceptance evidence |
| --- | --- | --- |
| Fully local | Generation, review, apply, tests and compilation execute on the device. Once required models, toolchains and dependencies are provisioned, the project works without Internet. Missing components are reported before work is lost. | Real local-model generation and a usable local artifact, offline rebuild, restart and follow-up edit. No remote build dispatch. |
| Fully online | Supported remote executors, such as GitHub, perform the expensive work. The device retains the authoritative project, attempt history and recovery state. | Real remote job, verified result/artifact provenance, interruption recovery and clear account/resource failures. |
| Hybrid | An explicit plan assigns different stages to local and remote resources to reduce time, battery or memory pressure. | Evidence for both local and remote stages of the same logical project, with validated transfers and resumable state. |

Automatic provider selection and remote-to-local fallback do **not** by
themselves demonstrate a hybrid build. Inference routing and build routing
are separate decisions. A local build with cloud generation is not the fully
local path.

## Shared ownership and platform boundaries

One repository, common main and shared Project/Task/Execution/Attempt contracts
remain authoritative. Platform-specific toolchains and resource policies are
adapted independently. Android's initial GitHub build path must not become a
requirement for Windows, and ASUS budgets must not become Android defaults.

General improvements go through small verified PRs to main. Windows/ASUS-only
development is retained on its dedicated platform branch. Concurrent workers
use separate checkouts, exact scopes, fresh main checks and resource checks
before starting a local model or a heavy build.

## Current implementation limits

Build Lab currently exposes `offlineLocal`, `local`, `remote`, `automatic`.
`WorkshopBuildProviderPolicy.remotePreferred` orders existing providers;
it does not partition a build into a hybrid plan.
`WorkshopLocalToolchainManager` manages component files, while
`WorkshopVerifiedLocalBuildProvider` connects detection to the local executor.
These existing boundaries should be extended, rather than replaced by a
second production lifecycle. Complete managed Windows provisioning and the
hybrid execution path still require implementation and physical acceptance.

The ASUS first-app acceptance must use actual local model responses. The
deterministic Android CI counter remains an orchestration regression test,
not evidence that local models generated a physical Windows application.
