# Bridge contract checks

The bridge is intentionally fail-closed. Before any transport call it verifies that the submission is accepted, targets the deterministic `intake/<asset>/<version>/manifest.json` path, remains in `discovered` state, and carries a 64-hex SHA-256 payload digest.

Transport rejection is surfaced as a bridge failure. No transport implementation is allowed to promote lifecycle state; certification remains a Module Library responsibility.
