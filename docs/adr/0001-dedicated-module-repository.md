# ADR 1: Dedicated Module Repository for `PS.GitHub`

## Status

Accepted

## Context

The `johnsarie27/ai` repository has accumulated a set of loose PowerShell
helpers that wrap `gh` and the GitHub REST API — `Invoke-GhApi`, `New-GhBody`
patterns, `gh auth status`-parsing preflights, tag-to-commit-SHA resolution.
Some are dot-sourced across sibling repositories (`PS-MCS/gh-org` in
particular) by absolute path.

Three distinct pressures shape the placement decision:

- **Discovery + import ergonomics.** Loose `.ps1` files under
  `ai/scripts/functions/` have no autoload story. Every consumer script has
  to know where the file lives and dot-source it explicitly. Renaming or
  moving the helper is a coordinated multi-repo change.

- **Portability to CI environments that don't have the source repo.**
  Reconciler workflows in `PS-MCS/gh-org` run on GitHub-hosted runners that
  do not check out the `ai` repository. Any consumption path that depends
  on `ai` being on disk is unworkable for those workflows.

- **Long-term maintenance surface.** The helpers already have their own
  design conversation, their own release-worthy semantics (e.g. `-Paginate`
  behavior, silent-404 handling), and now their own test surface. Bundling
  them inside a general-purpose personal-utilities repo means they inherit
  that repo's release cadence, CI concerns, and issue-tracker noise.

Two shapes other than a dedicated repository were considered:

- **A.** Keep loose `.ps1` files under `johnsarie27/ai/scripts/functions/`
  and continue dot-sourcing by path from consumer repos.
- **B.** Move the helpers into an `ai/modules/PS.GitHub/` module inside the
  existing `ai` repo.

Shape A does not solve the discovery problem or the CI-portability problem.
Shape B solves discovery but not portability — a consumer repo would still
need `ai` cloned to `Install-Module -Path`. It also couples the module's
release cadence to `ai`.

## Decision

We will host `PS.GitHub` as a **dedicated public GitHub repository**
(`johnsarie27/PS.GitHub`), structured as a standard PowerShell module
(manifest + loader + `Public/` + `Private/` + `Tests/`). The repository
mirrors the layout conventions of `johnsarie27/SecurityTools`.

Consumers install by cloning the repo and running `Install-Module -Path` in
CI, or (later) via PSGallery once external demand justifies the publish
overhead.

## Consequences

The module gets its own README, CHANGELOG, ADR log, issue tracker, CI
workflow, and PSGallery-ready manifest. This makes the helpers discoverable
by any consumer — sibling repos, external contributors, or automated
agents — without cross-repo path assumptions.

The module can be evolved on its own release cadence without triggering
`ai`-repo churn or being blocked by unrelated work there.

However, this creates a new repository to maintain in isolation. Small
changes (e.g. adding a fifth helper) now require the full ceremony of a
branch, PR, CI run, and release tag rather than a single commit to `ai`.
For a module this small, the per-change overhead is real. It is justified
by the CI-portability requirement, which the alternatives do not satisfy.

Cross-repo drift is a new failure mode: if `PS-MCS/gh-org` reconcilers
continue to carry their own `common/Invoke-GhApi.ps1` copy in parallel with
this module, the two can diverge. A separate follow-on effort (tracked in
[`PS-MCS/gh-org#38`](https://github.com/PS-MCS/gh-org/issues/38)) migrates
those reconcilers to consume `PS.GitHub` directly and delete the copy.
