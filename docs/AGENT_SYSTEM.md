# Agent System Architecture — AI Orchestrator Core

## Overview

AI Orchestrator Core is evolving into a **modular multi-agent cognitive operating system**.  This document describes the cognitive architecture vision, the agent hierarchy, inter-agent communication, orchestration strategy, runtime topology, and the road toward full offline/online coexistence.

> **Current status**: All components in this document are **lightweight placeholder contracts**.  No real AI reasoning or external service calls are implemented yet.  The goal of this milestone is to establish stable architectural boundaries so that future implementations slot in without breaking the existing app.

---

## Cognitive Architecture Vision

```
┌──────────────────────────────────────────────────────────────────┐
│                    User / Application Layer                       │
│           (Flutter UI · BLoC · Feature modules)                  │
└────────────────────────┬─────────────────────────────────────────┘
                         │ goal / prompt
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│               MultiAgentOrchestrator                              │
│   (session lifecycle · strategy selection · agent registry)      │
└──┬─────────────────┬──────────────────┬───────────────────┬──────┘
   │                 │                  │                   │
   ▼                 ▼                  ▼                   ▼
OrchestratorAgent  ReasoningAgent  KnowledgeAgent      ToolAgent
(coordination)     (problem-       (retrieval /        (tool
                    solving)        verification)       execution)
                                                            │
                                                            ▼
                                                       RuntimeAgent
                                                    (platform bridge)
                                                            │
                                              ┌─────────────┴──────────────┐
                                              ▼                            ▼
                                      LocalAgentRuntime          CloudAgentRuntime
                                    (on-device execution)      (remote execution)
                                              └──────────┬─────────────────┘
                                                         ▼
                                                HybridAgentRuntime
                                              (automatic failover)
```

The system is deliberately **cognitive** in structure: each agent type maps to a distinct cognitive function (coordination, reasoning, memory, action) rather than a technical concern.

---

## Agent Hierarchy

### BaseAgent

`lib/core/agents/base_agent.dart`

The root abstract contract for every agent.  Defines:

- **Identity**: `id`, `name`, `description`
- **Lifecycle**: `initialize` · `activate` · `suspend` · `shutdown`
- **Communication**: `communicate(AgentMessage)`
- **Execution**: `executeTask(taskId, instruction, SharedContext)`

All specialised agents extend `BaseAgent`.

### OrchestratorAgent

`lib/core/agents/orchestrator_agent.dart`

**Role**: Strategic coordination.

- Decomposes a high-level goal into sub-tasks.
- Selects and delegates to specialist agents via `TaskDispatcher`.
- Aggregates results and maintains progress in `SharedContext`.
- At most one per orchestration session.

### ReasoningAgent

`lib/core/agents/reasoning_agent.dart`

**Role**: Problem-solving.

- Applies chain-of-thought / ReAct / tree-of-thought strategies (placeholder).
- Returns structured `ReasoningResult` with an ordered step trace.
- Exposes `strategyId` so the orchestrator can pick the best reasoner.

### KnowledgeAgent

`lib/core/agents/knowledge_agent.dart`

**Role**: Retrieval, search, and verification.

- `retrieve(query)` — fetch relevant entries from a knowledge source.
- `verify(claim)` — cross-check a claim against stored knowledge.
- `store(entry)` — persist new knowledge for future sessions.
- Backed by pluggable sources: SQLite, vector DB, external API.

### ToolAgent

`lib/core/agents/tool_agent.dart`

**Role**: Tool execution.

- Maintains a registry of `Tool` instances (from `core/tools/`).
- `executeTool(toolId, params)` — runs a named tool and returns `ToolAgentResult`.
- The only agent that holds direct references to `Tool` objects.

### RuntimeAgent

`lib/core/agents/runtime_agent.dart`

**Role**: Platform bridge.

- Holds a `RuntimeProvider` reference.
- `runCommand(command)` — forwards to the underlying runtime.
- The **only** agent allowed to reference `RuntimeProvider`.
- All other agents route platform commands through `RuntimeAgent` via `MessageBus`.

---

## Agent Lifecycle

Every `BaseAgent` follows this state machine:

```
created
   │
   ▼ initialize()
initialising
   │
   ▼ (done)
idle ◄──────────────────────────────────────┐
   │                                        │
   ▼ activate()                             │ activate()
active ──► suspend() ──► suspended ─────────┘
   │
   ▼ shutdown()  (from any state)
shutdown  (terminal)
```

Lifecycle events are broadcast on `MessageBus.lifecycleEvents` so that monitoring components can react without polling.

| Method | Transition |
|---|---|
| `initialize()` | `created → initialising → idle` |
| `activate()` | `idle/suspended → active` |
| `suspend()` | `active → suspended` |
| `shutdown()` | `* → shutdown` |

---

## Communication Flow

All inter-agent communication is mediated through the `MessageBus`.  Agents never hold direct references to each other.

```
Agent A                 MessageBus              Agent B
   │                        │                      │
   │── publish(msg) ────────▶│                     │
   │                        │── deliver(msg) ──────▶│
   │                        │                      │── communicate(msg)
   │                        │                      │   (handles locally)
   │                        │◄── publish(reply) ───│
   │◄── deliver(reply) ─────│                      │
```

### Message types (planned)

| `AgentMessage.type` | Direction | Purpose |
|---|---|---|
| `task_request` | Orchestrator → Specialist | Delegate a sub-task |
| `task_result` | Specialist → Orchestrator | Return a result |
| `status_update` | Any → Any | Report progress |
| `context_patch` | Any → Any | Update `SharedContext` |
| `tool_call` | ReasoningAgent → ToolAgent | Request tool execution |
| `tool_result` | ToolAgent → ReasoningAgent | Return tool output |
| `command_request` | Any → RuntimeAgent | Request platform command |
| `command_result` | RuntimeAgent → Any | Return command output |

### Event Routing

`EventRouter` provides a pub/sub layer for typed `AgentEvent`s:

- `emit(event)` — broadcast to all matching subscribers.
- `on(eventType, handler)` — subscribe to a specific event type.
- `replay(eventType, handler)` — catch up on recent history (late-join support).

### Shared Context

`SharedContext` carries session-scoped state across agents:

- Typed `get<T>` / `set<T>` / `remove` access.
- `merge(map)` for bulk updates.
- `persist()` / `restore()` for durable sessions.

---

## Orchestration Strategy

`MultiAgentOrchestrator` delegates coordination to a pluggable `OrchestrationStrategy`:

| Strategy | `id` | Description |
|---|---|---|
| Sequential | `'sequential'` | Sub-tasks run one after another. |
| Parallel | `'parallel'` | Independent sub-tasks run concurrently. |
| Hierarchical | `'hierarchical'` | Sub-goals delegated to sub-orchestrators. |
| Reactive | `'reactive'` | Re-plans based on intermediate results (ReAct loop). |

Strategies are swappable at construction time without changing the agent implementations.

### Task Dispatch

`TaskDispatcher` routes `AgentTask`s to the pool with four priority levels:

`critical > high > normal > low`

Planned dispatcher implementations: `RoundRobinDispatcher`, `CapabilityDispatcher`, `PriorityQueueDispatcher`.

---

## Runtime Topology

### LocalAgentRuntime

On-device execution with no network dependency:

- Android: `AndroidExecutor` (android_intent_plus)
- Desktop: shell commands (Windows / Linux / macOS)
- Future: WASM sandbox

### CloudAgentRuntime

Remote execution delegated to a managed service:

- OpenAI Assistants API
- Gemini Cloud
- Custom HTTP endpoint

### HybridAgentRuntime

Automatic failover between local and cloud:

```
HybridRoutingPolicy.localFirst:
  1. Try LocalAgentRuntime
  2. If unavailable/no-capacity → CloudAgentRuntime

HybridRoutingPolicy.cloudFirst:
  1. Try CloudAgentRuntime
  2. If offline/auth-failure → LocalAgentRuntime

HybridRoutingPolicy.race (future):
  Run both concurrently; use first result
```

This mirrors the local-first routing implemented in `InferenceService` and extends it to the full agent layer.

---

## Offline / Online Coexistence

The architecture is designed for **offline-first operation**:

1. `LocalAgentRuntime` is always attempted before cloud.
2. `KnowledgeAgent` supports a local SQLite source — no network required.
3. `SharedContext` is persistable to local storage.
4. `HybridAgentRuntime` with `localFirst` policy is the default configuration.
5. Cloud components degrade gracefully — the app remains fully functional without any API keys or connectivity.

When online connectivity is available, cloud runtimes and knowledge sources augment local capabilities without replacing them.

---

## Future Scalability

### Adding a new agent type

1. Extend `BaseAgent` in `core/agents/`.
2. Implement in a feature module or plugin.
3. Register with `MultiAgentOrchestrator.addAgent()`.
4. No changes needed to existing agents or the orchestrator.

### Adding a new runtime

1. Implement `LocalAgentRuntime` or `CloudAgentRuntime` in `native/runtime/` or `features/`.
2. Inject via `injection_container.dart`.
3. Wrap in `HybridAgentRuntime` if mixed-mode routing is needed.

### Adding a new orchestration strategy

1. Implement `OrchestrationStrategy` in a feature module.
2. Pass to `MultiAgentOrchestrator` constructor.
3. No changes needed to agents, dispatchers, or runtimes.

### Scaling to multi-device / federated agents

1. Implement `MessageBus` backed by WebSocket / gRPC.
2. Implement `SharedContext` backed by a distributed store (Redis, Firestore).
3. Deploy `CloudAgentRuntime` instances per region.
4. The `OrchestratorAgent` API is unchanged — it still calls `executeTask` and `communicate`.

---

## File Map

```
lib/core/agents/
├── agent.dart                  # Original Agent + AgentResult (backward compat)
├── base_agent.dart             # Full lifecycle BaseAgent contract
├── orchestrator_agent.dart     # Strategic coordinator contract
├── reasoning_agent.dart        # Problem-solving contract
├── knowledge_agent.dart        # Retrieval / verification contract
├── tool_agent.dart             # Tool execution contract
├── runtime_agent.dart          # Platform bridge contract
├── agent_lifecycle.dart        # AgentLifecycleState enum + events
├── agent_message.dart          # Inter-agent message envelope
├── message_bus.dart            # MessageBus abstract contract
├── task_dispatcher.dart        # TaskDispatcher + AgentTask + TaskResult
├── event_router.dart           # EventRouter pub/sub contract
└── shared_context.dart         # SharedContext contract

lib/core/orchestrator/
├── orchestrator.dart           # Existing single-agent orchestrator (unchanged)
├── orchestration_strategy.dart # Pluggable strategy contract
└── multi_agent_orchestrator.dart  # Future multi-agent coordinator (placeholder)

lib/core/runtime/
├── runtime_provider.dart       # Existing RuntimeProvider (unchanged)
├── local_agent_runtime.dart    # Local execution contract
├── cloud_agent_runtime.dart    # Cloud execution contract
└── hybrid_agent_runtime.dart   # Hybrid routing contract

docs/
├── MODULAR_ARCHITECTURE.md     # Layer boundaries and dependency rules
└── AGENT_SYSTEM.md             # This file — cognitive architecture vision
```

---

## Dependency Rules (summary)

| Module | May import | Must NOT import |
|---|---|---|
| `core/agents/` | `core/tools/`, `core/runtime/`, `core/memory/` | `native/`, `features/` |
| `core/orchestrator/` | `core/agents/`, `core/ai/`, `core/error/` | `native/`, `features/` |
| `core/runtime/` | `core/` | `native/`, `features/` |
| `features/` | `core/` | `native/` (use `core/runtime/` instead) |
| `native/` | `core/` | `features/` |

All three boundary checks are enforced with `grep` assertions in CI (see `docs/MODULAR_ARCHITECTURE.md`).
