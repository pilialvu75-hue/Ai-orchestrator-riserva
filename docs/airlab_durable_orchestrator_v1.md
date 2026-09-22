# AIRLAB Durable Orchestrator V1

Status: **merged / converged through PR #559**
Baseline date: **2026-09-22**
Parent baseline: `Ai-orchestrator-riserva@77df0b55d855763911c61e9a697d738a9e0c89d5`
AIrLab architecture baseline: `Ai_orchestrator-prova@f3d52d2c91c437e437e12872030495dd719d2ed6`

## Purpose

Durable Orchestrator V1 lets long-running Cantiere projects persist scheduling
state without depending on a live UI, chat, Future or provider call.

It is deliberately **not** a second Project/Execution lifecycle.

Authority remains:

```text
Cantiere
  Project / Task / Execution / checkpoint
  Reviewer / validation / owner approval / apply
                    |
                    v
Durable Orchestrator scheduling overlay
  dependency readiness
  external waits
  retry timing/classification
  event correlation/idempotency
  watchdog evidence
                    |
                    v
capability/provider/build adapters
```

## D0 audit / reuse map

| Existing component | State on baseline | Durable V1 action |
|---|---|---|
| `WorkshopTaskContract` | dependencies, status, acceptance criteria, checkpoint already exist | REUSE through a read-only durable projection |
| `WorkshopExecutionStore` | stable execution id, attempt id, provider binding, resume phase and cost journal already persist | REUSE; do not create another execution identity |
| `WorkshopProductionExecutionController` | production single-flight, retry/restart replay and validated-proposal recovery exist | REUSE in the later production wiring ring |
| `WorkshopProductionRecoveryCoordinator` | project-scoped persistent recovery exists | REUSE as project authority |
| `WorkshopCheckpointStore` | canonical checkpoint persistence abstraction exists | REUSE as Durable V1 storage adapter |
| `CloudBackgroundExecutionJournal` | detects interrupted Cloud requests and forbids blind replay | CONFIRM safety rule; durable external replay requires idempotency |
| PR #545 parking semantics | historical branch predating current main | SUPERSEDED by current-main durable scheduling semantics; do not revive blindly |
| AIrLab A1-A5 / PR #548 | controlled AIrLab execution through Reviewer/validation exists | REUSE |
| AIrLab issue #11 / A6 | completed by PR #558 on current main | REUSE explicit opt-in production runner; historical runner remains unchanged when disabled |
| GitHub Actions | existing build infrastructure | first intended WAITING_EXTERNAL adapter |

## V1 durable states

- `CREATED`
- `PLANNING`
- `READY`
- `RUNNING`
- `WAITING_EXTERNAL`
- `BLOCKED`
- `RETRYING`
- `VALIDATING`
- `COMPLETED`
- `FAILED`
- `CANCELLED`

Every persisted transition records:

- reason;
- UTC timestamp;
- previous state;
- next state;
- task id;
- project id;
- correlation id.

Project-level transitions use the reserved task identity `@project`.

## Task graph

The scheduler does not own task instructions or workspace mutations.

`WorkshopDurableTaskProjection` derives:

- task id;
- dependencies;
- required acceptance-criterion ids;
- current coarse lifecycle state;
- already recorded artifact ids;

from the authoritative `WorkshopTaskContract`.

Durable-only scheduling fields are:

- provider-neutral capability;
- retry policy;
- timeout;
- retry-not-before;
- external wait descriptor;
- operation/event idempotency keys;
- human-gate reason.

Independent READY tasks remain runnable while another task is
`WAITING_EXTERNAL`. The project must not globally freeze merely because one
CI/build/provider operation is still running.

## Event bus contract

V1 defines the closed technical event vocabulary:

- `project.created`
- `task.started`
- `task.completed`
- `task.failed`
- `ci.started`
- `ci.completed`
- `build.completed`
- `provider.failed`
- `artifact.ready`
- `validation.failed`
- `validation.passed`

External event envelopes contain only technical metadata and artifact
identifiers. They must not contain prompt text, source contents or credentials.

## WAITING_EXTERNAL and resume

Starting an external operation is split into two durable steps:

1. claim an operation idempotency key;
2. dispatch the external operation and record its external id;
3. transition the task to `WAITING_EXTERNAL`;
4. release the live call/thread;
5. continue independent runnable tasks;
6. later receive or discover the matching event;
7. persist its event idempotency key;
8. transition the task to validation/retry/failure;
9. continue scheduling.

A duplicate event does not create a second transition or external operation.

## Retry model

Retry is failure-class specific. V1 distinguishes at least:

- network error;
- rate limit;
- provider unavailable;
- build error;
- code error;
- invalid artifact;
- validation failure;
- timeout;
- policy block;
- unknown failure.

Retry policy carries a maximum attempt count, retryable failure set and a
retry-not-before delay. Non-retryable failures fail closed.

The next integration ring may add class-specific exponential/backoff hints from
the Intelligence Gateway/Resource Pool without changing this lifecycle
contract.

## Watchdog V1

The watchdog is evidence-driven and does not keep an infinite poll alive. It
can detect:

- RUNNING longer than the task timeout;
- WAITING_EXTERNAL past its timeout;
- an external completion event already available but not processed;
- a human-gated task blocked beyond a threshold.

A platform scheduler, webhook receiver or foreground reconciliation pass can
call the watchdog/reconciler. V1 does not require one permanent process.

## Idempotency boundary

Two persistent key sets exist in the V1 overlay:

- **operation keys**: claim before an external side effect such as a CI dispatch;
- **event keys**: record before applying an external completion event.

This prevents ordinary restart/re-delivery duplication when a single
authoritative orchestration store is used.

Cross-process/distributed compare-and-set is intentionally not faked by the
local checkpoint adapter. When Supabase/NAS/server workers become concurrent
writers, the same store interface must be backed by an atomic unique-key/CAS
implementation before multiple schedulers are allowed to dispatch the same
project concurrently.

## Human gate

Human intervention is reserved for a real gate such as:

- owner approval;
- authorization;
- spend/risk decision;
- missing functional decision;
- technical impossibility requiring a choice.

Normal task-to-task progression, retry within policy, external completion and
validation progression do not require a "continue" message.

## Legacy decisions / migration log

| Decision | Previous/current state | V1 status | Reason |
|---|---|---|---|
| Create a new AIrLab project state machine | conflicts with Architecture V1 | REJECTED | Cantiere remains lifecycle authority |
| Reuse Cantiere checkpoint persistence | available on main | CONFIRMED | avoids a second database |
| Reuse task graph metadata | `WorkshopTaskContract.dependsOn` exists | CONFIRMED | durable task is only a projection |
| Blind replay after process death | Cloud journal already forbids it | REJECTED | may duplicate work/spend |
| Persist idempotency before side effect/event application | missing generic contract | ADDED V1 | restart and webhook safety |
| Busy-wait for GitHub Actions | historical operational anti-pattern | REJECTED | use WAITING_EXTERNAL + event/reconciliation |
| Park project as cancelled | PR #545 identifies this as wrong | SUPERSEDED conceptually | parking must remain resumable |
| Merge stale #545 blindly | branch predates #546-#548 | REJECTED | converge on current main first |
| Wire AIrLab production through A6 | completed by PR #558 | CONFIRMED | explicit runner preserves canonical production boundary and fails closed |

## MVP evidence implemented in PR #549

Tests cover:

- durable recovery using a fresh orchestrator instance;
- dependency scheduling;
- CI task parked in WAITING_EXTERNAL while independent work stays runnable;
- CI completion resume;
- duplicate external-event suppression;
- operation idempotency;
- retryable versus terminal failure classes;
- watchdog detection and reconciliation;
- projection from canonical Cantiere task contracts.

## Next convergence rings

1. Durable core is merged (#549).
2. AIrLab A6 production runner is merged (#558).
3. Researcher repository_dispatch intake now materializes canonical Cantiere
   and Durable Orchestrator contracts (#559).
4. Connect the durable READY task to a real deployed execution worker; the
   current AIrLab `/v1/tasks` Cloudflare surface still uses the deterministic
   mock engine.
5. Add GitHub Actions/external-event reconciliation:
   dispatch -> durable run id -> WAITING_EXTERNAL -> completion event.
6. Add watchdog/reconciliation invocation from a durable scheduler/webhook
   surface.
7. Add atomic distributed orchestration storage before enabling multiple
   concurrent server workers for the same project.
8. Prove the requested end-to-end path:
   REQUEST -> PROJECT -> TASK -> COMMIT -> CI -> WAITING_EXTERNAL -> RESUME ->
   FIX/RETRY if needed -> VALIDATION -> ARTIFACT READY -> COMPLETED.
