# Agent pairing audit

Audited 2026-09-10 against commit de56748 and the existing uncommitted replay redesign.

[Read the full analysis](agent-pairing-audit.md).

The audit examines whether a human and an agent can observe the same context, perform the same meaningful operations, detect conflicting changes, and verify outcomes. It includes recording, live native actions, Safari, web recording, replay, annotations, transport, accessibility, and verification coverage.

Status: analysis complete; findings are not implemented. No application source was changed during the audit. Earlier replay changes remain separate working-tree changes.

Recommended order:

1. Prevent duplicate mutations, reject malformed requests, fix lifecycle error propagation, and drain web recording batches before finalization.
2. Introduce stable review identities and coherent read-only review snapshots.
3. Add shared semantic review commands, operation receipts, stale-context checks, and bounded change watching.
4. Complete native/web evidence and annotation parity; fix live targeting and observation lifecycle.
5. Complete UI accessibility and adversarial integration coverage; profile larger recordings before performance refactoring.

These are roadmap stages, not independent implementation specifications. Detailed execution plans should be scoped from the findings before implementation; protocol and state-model changes should not be improvised independently by separate implementers.

Considered and rejected as defects: old recording compatibility, user-owned permission/approval grants, Safari active-tab restrictions, native-only spatial traces, sampled rather than deterministic accessibility evidence, offline web resource blocking, and bounded live retention. Missing OpenAPI generation checking was also rejected: the repository already has that check. The actual schema issue is semantic disagreement with runtime output.
