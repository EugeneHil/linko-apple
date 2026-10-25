# ADR-0000: Record architecture decisions

- Status: accepted
- Date: 2026-10-25

## Context

Linko spans three repositories and several platforms. Decisions about dependencies, platform constraints and protocols must stay traceable after the conversation that produced them is gone.

## Decision

Significant decisions are recorded as short ADRs in `docs/adr/NNNN-title.md` with the sections Context, Decision, Consequences (plus Findings for spikes). A new dependency is never added without an ADR. ADRs that apply to all repositories live in `linko-apple/docs/adr/`.

## Consequences

Each ADR is reviewed in its own pull request to `develop`. Superseded ADRs are kept and marked as such.
