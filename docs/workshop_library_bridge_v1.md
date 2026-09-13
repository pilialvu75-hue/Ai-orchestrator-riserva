# Workshop -> Module Library bridge v1

This bridge transports only `WorkshopLibraryIntakeSubmission` instances that have already passed the Cantiere-side submission gate.

## Safety invariants

- Destination is the private `pilialvu75-hue/AI-Orchestrator-Module-Library` repository.
- Only `intake/<asset>/<version>/manifest.json` is eligible.
- Intake status must remain `discovered`; the Cantiere cannot write `tested` or `certified` state.
- Payload identity must remain SHA-256 pinned.
- Rejected submissions never reach the transport.
- Credentials and provider-specific GitHub/network logic stay outside the domain bridge.
- Library quarantine, normalization, validation, testing, certification and promotion remain authoritative in the Library repository.

The first implementation therefore introduces a fail-closed transport boundary rather than embedding repository credentials or direct GitHub writes into the Flutter application. A concrete authenticated adapter can be attached to this boundary without weakening the submission gate.
