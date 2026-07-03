# ADR 3: Rejected Function Scope for v0.1.0

## Status

Accepted

## Context

The initial design conversation for `PS.GitHub` inventoried a broader set
of candidate helpers than the four that shipped in v0.1.0. Deciding what
*not* to build was as important as deciding what to build, because the
module's design premise is a **narrow, curated** surface — every added
helper is a run-time surface that callers must remember exists in order to
benefit from it.

Four candidate helpers were considered and rejected. Each is documented
here so a future contributor understands *why* they are out of scope and
does not re-propose them without new evidence.

- **`Invoke-GhWrite` — a generic idempotent write wrapper.** The idea:
  wrap `PUT` / `POST` / `PATCH` calls with automatic `GET → diff → Apply`
  reconciliation and idempotent retry. In practice, every real reconciler
  observed to date (security-configurations, CODEOWNERS, Dependabot
  templates, org-roles assignment) has quirks that a generic wrapper
  cannot absorb: the security-configurations PUT-response is the only
  authoritative confirmation of the write (the GET returns `null` for
  the same field name); CODEOWNERS reconciliation needs managed-block
  marker preservation across Contents-API rewrites; Dependabot templates
  need a merge, not a replace. A generic wrapper would collapse to
  "please read the endpoint docs" for every caller anyway.

- **`Assert-GhEndpoint` — dev-time endpoint-shape guard.** The idea: warn
  the caller before making a request if the path shape doesn't match a
  known-good pattern (e.g. the org-roles read/write asymmetry between
  `GET /orgs/{org}/organization-roles/{role_id}/teams` and
  `PUT /orgs/{org}/organization-roles/teams/{team_slug}/{role_id}`). This
  requires a hand-maintained allowlist of "known asymmetric" endpoints,
  which is circular: we only learn an endpoint is asymmetric after being
  burned by it. A skill or checklist ("open the docs page before the first
  PUT") captures the discipline at author time, which is when it matters.

- **`Get-GhPaginated` — dedicated pagination helper.** The idea: separate
  function for paginated endpoints. `Invoke-GhApi -Paginate` already
  supports pagination via `gh api --paginate` (no flatten step needed).
  A dedicated helper would be a three-line convenience wrapper around that
  existing behavior — not a feature, and pure duplication.

- **Thin wrappers around `gh issue` / `gh pr` / `gh release` subcommands.**
  The idea: `New-GhIssue`, `Get-GhPr`, etc. `gh api` covers all of these
  at the REST level, and `New-GhBody` covers the body-authoring class of
  mistake. Subcommand wrappers would add surface area without preventing
  a documented failure — they exist purely as taste-preferential
  alternatives to `gh api`, which the ADR-1 premise of a **narrow** module
  rejects.

## Decision

We will **not** ship `Invoke-GhWrite`, `Assert-GhEndpoint`, `Get-GhPaginated`,
or thin wrappers around `gh issue` / `gh pr` / `gh release` in v0.1.0 or
subsequent releases unless one of the following occurs:

- A concrete, recurring incident is documented that the proposed helper
  would have prevented and no combination of existing v0.1.0 helpers can
  address.
- An external caller opens an issue with a real use case that the current
  surface cannot express.

Speculative "this seems useful" additions are declined.

## Consequences

The module stays small and each function has an unambiguous, incident-backed
justification. Contributors reading the source can trace every helper to
its motivating pain point without archaeology.

The tradeoff is friction for callers who *want* a subcommand wrapper.
Someone who prefers `New-GhIssue -Title X -Body Y` over `gh api
repos/o/r/issues -f title=X -f body=Y` gets the second shape only. This is
deliberate: the module's value is preventing mistakes, not providing a
more-pwsh-idiomatic surface over `gh`.

Rejecting `Invoke-GhWrite` in particular means each reconciler continues to
implement its own `GET → diff → Apply` loop with its own quirks. That is
correct — the quirks are load-bearing, not incidental — but it means the
"idempotent write" pattern is repeated verbatim across sibling scripts.
Callers should feel that repetition as a signal, not a defect.

This ADR should be re-examined if the follow-on migration of
`PS-MCS/gh-org` reconcilers surfaces genuinely-shared write behavior that
none of these rejected helpers can express. In that event, the next ADR
supersedes this one for the affected helper only.
