# ADR 11: Dated ADR Status Lines

## Status

Accepted — 2026-09-14

## Context

- The `adr` skill this repository follows extends Michael Nygard's 2011
  format with an ISO 8601 date on the `## Status` line — `Accepted —
  2026-09-14`. Nygard's original carries no date.
- ADR-0001 through ADR-0009 were authored without one. The skill suggests
  recording local format deviations in a repository's ADR-0001, but this
  repository's ADR-0001 governs a different subject (module placement),
  so there is no existing home for the convention.
- Without a date, a reader cannot tell when a decision took effect, and —
  once an ADR is superseded — cannot tell how long it stood.
- Git history is a poor substitute for that date here. This repository
  squash-merges and deletes the head branch (`deleteBranchOnMerge` is
  enabled; `main` carries zero merge commits across its history). A
  squashed commit records only the final state of each file, so any
  intermediate `Proposed` value on a branch never reaches `main`, and the
  branch commits that held it are unreachable from every local ref once
  the branch is deleted.
- The consequence is that `main` reads uniformly `Accepted` regardless of
  how any individual ADR was actually developed. That uniformity is an
  artifact of the merge strategy, not a record of process.
- The artifact actively misleads. While preparing this record, an agent
  ran `git log --all -S'Proposed' -- docs/adr`, got no output, and
  concluded the repository had never used a `Proposed` phase. The check
  was structurally incapable of finding one. GitHub's retained pre-squash
  PR commits show that nine ADRs were in fact authored `Accepted` in
  their first branch commit — a fact about those nine, not a rule about
  the repository.
- Drafting an ADR as `Proposed`, doing the work that validates the
  decision, and flipping it to `Accepted` before the final merge is a
  normal and expected path here. Nothing in the tree records that,
  because nothing in the tree can.

## Decision

- Every ADR's `## Status` value carries an ISO 8601 date recording when
  that status took effect: `Accepted — 2026-09-14`. The date is rewritten
  in place whenever the status changes, alongside the status itself.
- Dates for ADR-0001 through ADR-0009 are backfilled from the commit that
  introduced each file to `main`, read from git rather than estimated.
- This record documents a format field and explains an artifact of the
  repository's history. It does not constrain the ADR lifecycle: the
  `Proposed → Accepted` path remains available and expected whenever a
  decision needs validating before it is committed to.

## Consequences

Positive:

- A reader can date any decision without archaeology, and can measure how
  long a superseded decision stood.
- The uniform `Accepted` reading of the tree now has a written
  explanation, so the next reader — human or agent — does not have to
  infer a process rule from a merge-strategy artifact.

Negative:

- The backfilled dates are **repository-entry** dates, not deliberation
  dates. ADR-0001 through ADR-0007 all read `2026-07-02` because they
  shipped in a single scaffold PR; that overstates how simultaneous those
  seven decisions actually were.
- For any ADR that did pass through `Proposed`, the recorded date marks
  the merge, not the moment of agreement, which may predate it by days.
  The date is an upper bound on when the decision was made, not the
  moment itself.
- The Status line becomes a field that must be maintained on every status
  change, including supersession. It will be forgotten at some point, and
  a stale date is worse than an absent one because it reads as authority.
- ADR deliberation history — the `Proposed` state, the PR discussion that
  moved it — lives only in GitHub's retained pre-squash PR commits, not
  in git. It does not survive mirroring the repository off GitHub, and it
  is not available to anyone working from a clone alone.

Neutral:

- Squash-merge is not reconsidered here. Its benefits to `main`'s
  readability are being paid for with the loss of intra-branch history,
  and that trade is accepted; this record only documents what it costs
  the ADR log specifically.
- No index file is introduced. The skill treats one as optional below
  roughly twenty records, and a directory listing still serves.
