# ADR 5: Multi-OS CI Matrix (`ubuntu-latest` + `windows-latest`)

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
  Linux PowerShell hosts.

- **Path handling in the module loader and Build/ harness.** The `.psm1`
  loader and PSake `Build/build.psake.ps1` use `Join-Path`, but shared
  string paths like `"$ProjectRoot/Tests/*/*.tests.ps1"` mix separators.
  Windows tolerates forward slashes in most contexts but not all; Linux
  is stricter.

- **Temp path resolution.** `[IO.Path]::GetTempFileName()` and
  `[IO.Path]::GetTempPath()` return different roots on Windows
  (`%TEMP%\`, typically under the user profile) versus Linux (`/tmp/`).
  Permission behaviors also differ.

Author-time work happens on Windows. The most-likely CI consumer of the
module (`PS-MCS/gh-org` reconciler workflows) runs on GitHub-hosted
`ubuntu-latest` runners. Single-OS CI would leave one of the two
production surfaces unverified on every change.

Three CI matrix shapes were considered:

- **A.** `windows-latest` only. Fast, cheap, matches author-time. Ships
  Linux-only bugs blind.

- **B.** `ubuntu-latest` only. Fast, cheap, matches the most-likely CI
  consumer. Ships Windows-only bugs blind.

- **C.** Both. Runs twice per commit; ~30 seconds more clock time per
  push on parallelizable workflows; costs nothing on public repos.

## Decision

We will run CI on a **`[ubuntu-latest, windows-latest]`** matrix, with
`fail-fast: false` so both legs report even when one fails. Both legs
run the identical PSake pipeline (`Init` → `CombineFunctionsAndStage` →
`Analyze` → `Test`). The `PowerShellVersion` floor in the module manifest
is `7.4` (current LTS).

macOS is intentionally excluded from the matrix. No known caller runs the
module on macOS in CI, and it is not a supported production surface.

## Consequences

Every merge to `main` is verified on the two platform combinations that
represent author-time (Windows) and expected consumption (Linux). Line-
ending divergence in the temp-file writer, path-separator inconsistencies
in the harness, and any temp-path resolution subtlety surface at PR time
rather than at first external consumption.

The tradeoff is duplicated CI cost. On a public repository this is free
in wall-clock terms (GitHub-hosted parallel runners); on a hypothetical
future private-repo mirror it is a real cost. If cost pressure ever
materializes, drop `windows-latest` first — Linux is the more-likely
consumer surface — and revisit this ADR.

The decision also commits us to the PSake harness working on Linux, which
requires forward-slash-tolerant path construction throughout
`Build/build.psake.ps1` and the `.psm1` loader. Any future contributor
adding a build task must confirm it works cross-platform before merging.

The macOS exclusion is a real gap. If the module is ever adopted by a
macOS-based agent workflow, this ADR should be superseded with one that
adds `macos-latest` to the matrix.
