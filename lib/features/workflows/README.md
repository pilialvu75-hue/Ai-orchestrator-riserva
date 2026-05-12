# lib/features/workflows/

Feature module for building and running multi-step AI workflows.

Workflows chain together agents, tools, and AI calls into repeatable pipelines.
Users can define workflows visually or via YAML templates.

## Planned Contents

- `domain/` — Entities (Workflow, WorkflowStep, WorkflowResult) and use cases
- `data/` — YAML/JSON workflow definitions and execution history
- `presentation/` — BLoC, pages, and widgets for the Workflows screen
