# Cantiere -> AIrLab integration v1

This first integration layer is intentionally transport-only. It proves that AI-Orchestrator Cantiere can discover AIrLab, read capabilities and submit a task without knowing where a future LLM runs.

## Invariants

- no real LLM is required;
- no NAS, GPU or external provider is required;
- the client is browser-safe and does not import `dart:io`;
- AIrLab unavailability is represented explicitly instead of silently falling back to another runtime;
- authentication is optional on loopback and may be supplied for protected remote endpoints;
- provider keys and GitHub credentials are not part of the AIrLab task payload.

## First endpoints

- `GET /health`
- `GET /v1/capabilities`
- `POST /v1/tasks`

## Task families

The transport already supports the platform-level families defined by AIrLab: `software`, `web`, `cad`, and `manufacturing`. This does not mean that real CAD or slicing is implemented yet; it only freezes a stable extensible contract before adding specialist engines.

## Next gate

Wire this client behind a Cantiere execution adapter and prove a deterministic request/response round trip against the AIrLab mock service. Only after that gate is green should a real model adapter be introduced.
