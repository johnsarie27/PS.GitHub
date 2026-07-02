# ADR 5: Multi-OS CI Matrix (`ubuntu-latest` + `windows-latest` + `macos-latest`)

## Status

Accepted

## Context

`PS.GitHub` is a PowerShell 7 module. PowerShell 7 targets .NET and runs
on Windows, Linux, and macOS. The module's runtime interactions are
almost entirely with the `gh` CLI, the GitHub REST API over HTTPS, and
temp files. None of those are inherently platform-specific.

Three platform-shaped risks are nonetheless present:

- **Line endings in `New-GhBody` temp files.** The module's whole reason
  to exist for bodies is preventing hard-wrapped GitHub renders. The temp
  file is written by PowerShell and read by `gh`, which pipes the content
  to the GitHub API. Whether the file has LF or CRLF line endings, and
  whether `gh` normalizes them, affects the rendered output on the issue
  or PR page. This has been observed to differ subtly between Windows and
  Linux PowerShell hosts and could plausibly differ again on macOS.

- **Path handling in the module loader and Build/ harness.** The `.psm1`
  loader and PSake `Build/build.psake.ps1` use `Join-Path`, but shared
  string paths like `"$ProjectRoot/Tests/*/*.tests.ps1"` mix separators.
  Windows tolerates forward slashes in most contexts but not all; Linux
  and macOS are stricter.

- **Temp path resolution.** `[IO.Path]::GetTempFileName()` and
  `[IO.Path]::GetTempPath()` return different roots on Windows
  (`%TEMP%\`, typically under the user profile), Linux (`/tmp/`), and
  macOS (`/var/folders/...` under the user's private temp namespace).
  Permission behaviors also differ.

The module's stated purpose is to give AI agents and their workflows a
safer surface for interacting with `gh` and the GitHub API. Those agents
run in whatever environment the human they are helping happens to work
in — Windows workstations, Linux devcontainers and Codespaces, macOS
laptops, and Linux GitHub-hosted runners for the follow-on reconciler
migration. Excluding any of the three primary desktop / server OSes from
CI leaves that OS's users to discover regressions the hard way.

Author-time work today happens on Windows. The most-likely near-term CI
consumer (`PS-MCS/gh-org` reconciler workflows) runs on GitHub-hosted
`ubuntu-latest` runners. A future agent session on macOS is a plausible
surface even though none is confirmed today.

Four CI matrix shapes were considered:

- **A.** `windows-latest` only. Fast, cheap, matches author-time. Ships
  Linux- and macOS-only bugs blind.

- **B.** `ubuntu-latest` only. Fast, cheap, matches the most-likely
  server-side consumer. Ships Windows- and macOS-only bugs blind.

- **C.** `ubuntu-latest` + `windows-latest`. Covers the two verified
  production surfaces; treats macOS as "not supported".

- **D.** All three (`ubuntu-latest` + `windows-latest` + `macos-latest`).
  Wall-clock cost is unchanged from **C** because GitHub-hosted runners
  execute matrix legs in parallel; monetary cost on a public repository
  is zero.

## Decision

We will run CI on a **`[ubuntu-latest, windows-latest, macos-latest]`**
matrix, with `fail-fast: false` so all three legs report independently.
Each leg runs the identical PSake pipeline
(`Init` → `CombineFunctionsAndStage` → `Analyze` → `Test`). The
`PowerShellVersion` floor in the module manifest is `7.4` (current LTS).

This supersedes an earlier draft of this same ADR (never merged) that
restricted the matrix to `ubuntu-latest` + `windows-latest` and
explicitly excluded macOS. That framing was inconsistent with the
module's premise of being useful to any agent regardless of the OS the
human it is helping happens to be on.

## Consequences

Every merge to `main` is verified on all three PowerShell 7 desktop /
server targets. Line-ending divergence in the temp-file writer,
path-separator inconsistencies in the harness, and any temp-path
resolution subtlety surface at PR time rather than at first external
consumption. macOS-specific surprises (e.g. BSD `sed` semantics if
tooling ever shells out, or the private-namespace temp path being longer
than Windows-style code assumes) are caught at PR time too.

The cost is a third parallel CI leg per push. On a public repository
GitHub-hosted parallel runners make this free in both wall-clock and
monetary terms. On a hypothetical future private-repo mirror the third
leg would add real minutes; if that cost ever materializes, drop
`macos-latest` first (fewest known consumers), then `windows-latest`,
revisiting this ADR in a supersession.

The decision commits us to the PSake harness and every function shipping
after v0.1.0 working on all three OSes. Any future contributor adding a
build task or function must confirm it works cross-platform before
merging. Windows-only or Unix-only paths in production code require an
explicit ADR-level justification.

The `.tests.windows.ps1` filename pattern present in the SecurityTools
template was intentionally not copied into this module's PSake harness
(see PR-A commit `3b41920`): a cross-platform-by-default module has no
place for a Windows-only test filename discriminator that would only
surface as CI-green Linux/macOS legs skipping tests they should be
running.


The macOS exclusion is a real gap. If the module is ever adopted by a
macOS-based agent workflow, this ADR should be superseded with one that
adds `macos-latest` to the matrix.
