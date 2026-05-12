# lib/core/agents/

Abstract contracts for the multi-agent cognitive system.

Agents are specialised units that can independently:
- Plan and execute multi-step tasks
- Use tools to interact with the environment
- Communicate with other agents via the `MessageBus`
- Operate offline or delegate to cloud runtimes

## Contents

### Contracts

| File | Contract | Role |
|---|---|---|
| `agent.dart` | `Agent` / `AgentResult` | Original minimal contract (backward-compat) |
| `base_agent.dart` | `BaseAgent` | Full lifecycle + communication contract |
| `orchestrator_agent.dart` | `OrchestratorAgent` | Strategic coordination |
| `reasoning_agent.dart` | `ReasoningAgent` | Problem-solving / chain-of-thought |
| `knowledge_agent.dart` | `KnowledgeAgent` | Retrieval / search / verification |
| `tool_agent.dart` | `ToolAgent` | Tool execution |
| `runtime_agent.dart` | `RuntimeAgent` | Platform bridge |

### Communication Abstractions

| File | Contract | Purpose |
|---|---|---|
| `agent_lifecycle.dart` | `AgentLifecycleState` / `AgentLifecycleEvent` | Lifecycle state machine |
| `agent_message.dart` | `AgentMessage` | Inter-agent message envelope |
| `message_bus.dart` | `MessageBus` | Publish/subscribe message routing |
| `task_dispatcher.dart` | `TaskDispatcher` / `AgentTask` / `TaskResult` | Task dispatch and scheduling |
| `event_router.dart` | `EventRouter` / `AgentEvent` | Typed event pub/sub |
| `shared_context.dart` | `SharedContext` | Session-scoped shared state |

## Dependency Rule

```
core/agents/ ← features/ agent implementations
core/agents/ → core/tools/, core/runtime/, core/memory/  (within-core allowed)
core/agents/ → native/                                    (FORBIDDEN)
```

See `docs/AGENT_SYSTEM.md` for the full cognitive architecture vision.
