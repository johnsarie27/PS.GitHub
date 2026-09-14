# ADR 10: Atomic Ref Move via a Throwaway Branch in `New-GhSignedCommit`

## Status

Accepted — 2026-09-14

## Context

- `New-GhSignedCommit` exists to produce exactly one GitHub-signed commit
  on top of `-BaseBranch`'s tip, rather than stacking a commit onto
  whatever was already on `-HeadBranch`.
- The GraphQL `createCommitOnBranch` mutation parents the new commit on
  the target branch's current head. To get the base tip as the parent,
  the target branch must already be at the base tip when the mutation
  runs.
- Through v0.3.0 the function achieved that with two ref updates:
  force-reset `-HeadBranch` to `baseSha` (`PATCH /git/refs/heads/...`),
  then run the mutation.
- Between those two updates `-HeadBranch` **equals** `-BaseBranch` and is
  zero commits ahead. That is precisely the condition GitHub uses to
  auto-close a pull request.
- Issue #29: an open PR on `-HeadBranch` is therefore closed silently.
  The mutation then lands correctly, so the branch ends up right and the
  PR does not; the follow-up ref update does not reopen it, and nothing
  in the function's output signals that it happened.
- Observed twice: `PS-MCS/gh-org#140` (PR auto-closed, recovered with
  `gh pr reopen`), and a near-miss on `jjohns-dev/pwsh-module-ci#5`
  avoided only because the failure mode was already known.
- The end state was never the problem. The *intermediate* state is.
- `createCommitOnBranch` requires a real branch under `refs/heads/`; it
  cannot commit to a detached or non-branch ref. So "create the commit
  first, then move the branch" needs somewhere to put the commit.

Forces:

- The contract must not change. Live callers depend on the
  single-commit-off-base shape.
- Append-by-default is not acceptable; discarding the prior head is the
  behavior the function exists to provide.
- Any scratch ref must be cleaned up even when the mutation fails.

## Decision

Replace reset-then-commit with commit-then-move:

1. `POST /git/refs` creating a throwaway branch
   `ps-github/tmp/<guid>` at `baseSha`.
2. `createCommitOnBranch` against the throwaway, with
   `expectedHeadOid = baseSha`, yielding `newOid`.
3. Move `-HeadBranch` to `newOid` in a **single** ref update:
   `PATCH ... force=true` when it exists, `POST /git/refs` when it does
   not.
4. `DELETE` the throwaway ref in a `finally`.

Supporting choices:

- **Applied unconditionally**, including when `-HeadBranch` does not yet
  exist and no PR could possibly be open. One code path yields one
  invariant to state and to test — "`-HeadBranch` is never observed
  equal to `-BaseBranch`" — rather than "atomic when the branch exists,
  reset when it does not."
- **Fixed, recognizable prefix** `ps-github/tmp/` so a consumer repo can
  exclude the throwaway from workflow `branches:` filters or ruleset
  conditions, and so orphans are greppable.
- **No new parameters.** The contract, the returned oid, and the end
  state are unchanged.
- Comment-based help now states the replace-not-append semantics
  outright, which issue #29 called for independently of the fix.

## Consequences

Positive:

- `-HeadBranch` transitions directly from its old head to the new signed
  commit. It is never zero commits ahead of base, so no open PR is ever
  auto-closed.
- End state is byte-identical to v0.3.0: one signed commit parented on
  the base tip, prior head discarded.
- Cleanup of the throwaway is the function's problem, not the caller's,
  consistent with ADR-2's treatment of `New-GhBody` temp files.

Negative:

- Two extra ref writes per call (create plus delete), four total instead
  of two. Negligible against the mutation itself, but not free.
- The throwaway branch briefly exists and is visible in the repo's event
  stream. It will trigger workflows keyed on `on: push` with no
  `branches:` filter or `branches: ['**']`, and on `on: create` /
  `on: delete`. Verified to affect no current consumer — this repo's
  workflows are `push: branches: [main]` plus `pull_request`, and both
  `PS-MCS/gh-org` rulesets scope to `~DEFAULT_BRANCH` — but it is a real
  latent cost for a future consumer repo.
- A killed process between create and delete leaves an orphan
  `ps-github/tmp/<guid>` branch. `finally` covers thrown errors, not
  `SIGKILL`. Accepted: orphans are harmless and the prefix makes them
  trivially findable.
- A ruleset restricting branch *creation* across all refs would now
  block the function where it previously succeeded.

Neutral:

- The `expectedHeadOid` guard is retained but can no longer fire: the
  throwaway is created at `baseSha` by this same call under a name no
  other writer knows. The concurrent-base-move race it nominally guarded
  is inherent and unchanged either way; the field stays because it costs
  nothing and documents the intended parent.
- Ships as a Build/patch bump (0.3.1). No new surface area, no signature
  change — a defect fix, unlike ADR-9's Minor bump for a new parameter.

Rejected alternatives:

- **Document only.** Cheapest, but leaves a destructive default behind a
  help topic. The footgun has already fired twice; "read the help first"
  is a weak control.
- **Append by default, `-Reset` to opt in.** Safer default, but breaks
  existing callers and gives up the clean single-commit outcome the
  function exists to produce.
