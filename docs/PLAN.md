# PS.GitHub — build plan

**Status:** approved, not yet started
**Tracking issue:** [#1](https://github.com/johnsarie27/PS.GitHub/issues/1)
**Target first tag:** `v0.1.0`

This document is the working plan for the v0.1.0 build of `PS.GitHub`. It is intentionally kept in-repo (not in the issue, not in session memory) so future contributors — human or agent — can read it end-to-end without external context.

The tracking issue (#1) captures the *design rationale* (what pain points, what shape decisions, what was rejected and why). This document captures the *execution plan* that follows from those decisions.

## Locked decisions

These were agreed with the repo owner before scaffolding began. Change them only via a follow-up commit that also updates this section (or an ADR that supersedes the decision).

| # | Area | Decision | Rationale |
|---|---|---|---|
| D1 | Source of `Invoke-GhApi` | Port unchanged from `PS-MCS/gh-org/common/Invoke-GhApi.ps1` via `gh api`/clone | Working, battle-tested reference implementation. Re-implementing risks regression on subtle behaviors (silent-404, empty-204, `string[]` normalization). |
| D2 | Source of `Test-GhAuthScope` | Extract and generalize the `gh auth status`-parsing preflight from `PS-MCS/gh-org`. **RESOLVED 2026-07-02:** the referenced `temp-migration/` path was cleaned up post-migration. The canonical source is now three near-identical inline blocks in `dependabot/Invoke-PSMCSDependabotReconcile.ps1` (~line 89), `codeowners/Invoke-PSMCSCodeOwnerReconcile.ps1` (~line 94), and `github-perms/Invoke-PSMCSTeamPermissionReconcile.ps1` (~line 143). Pattern: `$authStatus = & gh auth status 2>&1 \| Out-String` then `-notmatch` regex against a scope set, with `Write-Error -ErrorAction Stop` on miss including the concrete `gh auth refresh -h github.com -s <scope>` remediation. `Invoke-GhApi.ps1` deliberately does NOT include the preflight — it's scope-agnostic and defers to callers. | Same repo already proved the pattern against real `gh auth status` output shapes. |
| D3 | Module layout template | Mirror `johnsarie27/SecurityTools` | Consistent with owner's other public modules; established `Public/` / `Private/` / `Tests/` / `Build/` convention. |
| D4 | `New-GhBody` disposal shape | `ScriptBlock` wrapper only: `New-GhBody -Text $b -ScriptBlock { param($path) ... }` with cleanup in the function's `finally`. | Module is primary consumer is AI agents, not humans. ScriptBlock-only makes cleanup impossible to forget (safe by construction); explicit-cleanup shapes require the caller to remember `try`/`finally`, which is exactly the class of miss the module exists to prevent. |
| D5 | CI matrix | `ubuntu-latest` + `windows-latest` + `macos-latest`, PS 7.4 LTS floor | Every current and expected consumer runs on a different OS: author-time is Windows, agent devcontainers/Codespaces are Linux, likely reconciler consumers (`PS-MCS/gh-org`) are Linux, and a future agent session on macOS is plausible. Excluding any of the three would let regressions ship blind on that platform. GitHub-hosted parallel runners make the three-leg matrix effectively free in wall-clock and monetary terms on a public repo. PS 7.4 LTS is the current PSGallery-consumer alignment point; nothing in v0.1.0 needs 7.6+. |
| D6 | Publishing | v0.1.0 = git tag only. No PSGallery push. Consumer repos install via `Install-Module -Path <checkout>`. | Defers a `PSGALLERY_API_KEY` secret and prerelease-tag workflow until real consumer demand exists. |
| D7 | Repo-scoped agent instructions | Add `AGENTS.md` at repo root as the single source of truth for agent conventions | Current GitHub Copilot builds read `AGENTS.md` natively at the repo root, and other agent frameworks (Aider, Cursor, etc.) recognize the same convention. A separate `.github/copilot-instructions.md` was originally added as a belt-and-suspenders pointer, then removed on the same PR-A branch (see PR-A commit history) once we verified Copilot picks up `AGENTS.md` directly. If a future tool requires its own pointer file, add it then, not preemptively. |
| D8 | Architectural record | ADRs under `docs/adr/NNNN-title.md`, Michael Nygard 5-section format | Several decisions above (D3, D4, D5, and the rejected-function-scope list in #1) are exactly the kind of "affects public interface / project-wide convention" decisions the `adr` skill is designed for. |

## v0.1.0 function scope

Priority order = build order = commit/PR order (see execution plan below).

1. **`Invoke-GhApi`** — foundation. Wrapper around `gh api` with pagination (`--paginate` + `.[]` flatten), `-Method`/`-Body`, silent-404 for optional resources, empty-204 short-circuit, `string[]`→`string` boundary normalization. Internally invokes `gh` through the private `Invoke-Gh` helper (see below), which owns the `$PSNativeCommandUseErrorActionPreference = $false` isolation and the structured-output shape.
2. **`New-GhBody`** — authored-body handling. Enforces one-paragraph-per-line (no reflex hard-wrapping at 72–80 cols), writes body to a temp file, invokes the caller's `-ScriptBlock` with the path, cleans up the temp file in `finally` even on exceptions.
3. **`Test-GhAuthScope`** — preflight. Parses `gh auth status 2>&1`; asserts required OAuth scopes; on missing scope, `Write-Error -ErrorAction Stop` with the exact `gh auth refresh -h github.com -s <scope>` remediation string in the message. Invokes `gh auth status` through the private `Invoke-Gh` helper.
4. **`Resolve-GhCommitSha`** — tag/branch/SHA → commit SHA via `GET /repos/{o}/{r}/commits/{ref}`. Avoids the annotated-tag-object trap of `/git/refs/tags/{tag}`. Optional `-CrossCheck` fetches both shapes and warns on disagreement. Uses `Invoke-GhApi` (indirectly `Invoke-Gh`).

Private helpers (dot-sourced by `PS.GitHub.psm1`, not exported):

- **`Invoke-Gh`** (Private) — lowest-level `gh` wrapper, modeled on `PS.DCU/Private/Invoke-DCU.ps1`. Structurally enforces ADR-4 (`$PSNativeCommandUseErrorActionPreference = $false` in exactly one place) and ADR-6 (single choke point for `string[]` boundary normalization + consistent structured return shape `{ ExitCode, Output, Arguments, Duration }`). Every public function that invokes `gh` goes through it; direct `& gh` calls in `Public/` are a review-reject.

**Explicitly out of scope for v0.1.0** (kept here for transparency; full rationale lives in #1):

- `Invoke-GhWrite` (generic idempotent write wrapper)
- `Assert-GhEndpoint` (dev-time endpoint-shape guard)
- `Get-GhPaginated` (redundant with `Invoke-GhApi -Paginate`)
- Thin wrappers around `gh issue` / `gh pr` / `gh release` subcommands
- GitHub App / installation-token auth flow
- Filesystem-side git operations (`git commit`, `git push`, tag creation)

## Cross-cutting rules the module bakes in

Every public function honors these; they are also documented in `AGENTS.md`:

1. **`$PSNativeCommandUseErrorActionPreference` isolation.** Enforced structurally by the private `Invoke-Gh` helper (ADR-6) so no public function needs to remember to set it. Direct `& gh` calls in `Public/` are a review-reject.
2. **`string[]` normalization at the boundary.** Any `-Body`/`-Text` parameter is passed through `Out-String` / `-join "`n"` inside `Invoke-Gh` before being handed to a typed `[System.String]` gh argument.
3. **No `--jq` / `--query` for filter/project.** Module returns deserialized objects; callers use the pwsh pipeline. The one internal `--jq '.[]'` use is inside `Invoke-GhApi -Paginate`'s flatten step.
4. **Temp-body lifecycle is never the caller's problem.** `New-GhBody` owns creation and disposal end-to-end.

## Planned repo layout after v0.1.0

```
PS.GitHub/
  .devcontainer/
  .github/
    workflows/
      ci.yml
  .vscode/
  AGENTS.md
  Build/
  CONTRIBUTING.md
  docs/
    PLAN.md              # this file
    adr/
      0001-dedicated-module-repository.md
      0002-scriptblock-wrapper-for-body-lifecycle.md
      0003-rejected-function-scope.md
      0004-native-command-preference-isolation.md
      0005-multi-os-ci-matrix.md
      0006-private-invoke-gh-wrapper.md
  LICENSE                # already present (MIT)
  PS.GitHub.psd1
  PS.GitHub.psm1
  Private/
    Invoke-Gh.ps1        # lowest-level gh wrapper; not exported
  Public/
    Invoke-GhApi.ps1
    New-GhBody.ps1
    Resolve-GhCommitSha.ps1
    Test-GhAuthScope.ps1
  README.md              # replace current stub
  Tests/
    Invoke-GhApi.Tests.ps1
    New-GhBody.Tests.ps1
    Resolve-GhCommitSha.Tests.ps1
    Test-GhAuthScope.Tests.ps1
```

## Execution plan — five PRs, chunked for reviewability

Each PR references issue #1 and closes one sub-item of its build checklist. Issue #1 closes when PR-E lands. Every PR includes its own tests and passes CI green before merge.

### PR-A — Scaffold, conventions, CI, ADRs *(no functional code)*

- Fetch reference sources via `gh` for D1, D2, D3.
- Create module skeleton: `PS.GitHub.psd1`, `PS.GitHub.psm1` (dot-source loader for `Public/`, `Private/`), empty `Public/`, `Private/`, `Tests/`, `Build/`, `.gitignore`.
- Port `.vscode/` and `.devcontainer/` conventions from `SecurityTools`.
- Add `.github/workflows/ci.yml` — matrix `[ubuntu-latest, windows-latest]`, PS 7.4, Pester + PSScriptAnalyzer, `permissions:` locked to minimum, third-party actions pinned by commit SHA (per `github-actions-security` skill).
- Add `AGENTS.md` (repo conventions + four cross-cutting rules) at the repo root. Current Copilot builds read this natively; no `.github/copilot-instructions.md` needed.
- Add the 5 ADRs listed under D8.
- Replace stub `README.md` with real content (purpose, install-via-path, quickstart, function list, contributing pointer).
- Add `CONTRIBUTING.md`.

### PR-B — `Invoke-Gh` (Private) + `Invoke-GhApi` (Public) + tests

- Author `Private/Invoke-Gh.ps1` — the lowest-level `gh` wrapper. Modeled on `johnsarie27/PS.DCU/Private/Invoke-DCU.ps1` but simplified (no `Start-Process` needed — `gh` streams cleanly through `& gh @Arguments 2>&1`, and stdin pipes via `--input -`). Structural enforcement of ADR-4 (`$PSNativeCommandUseErrorActionPreference = $false` in one place) and ADR-6 (`string[]` normalization + `{ ExitCode, Output, Arguments, Duration }` return shape).
- Port `Public/Invoke-GhApi.ps1` from `PS-MCS/gh-org/common/Invoke-GhApi.ps1`, refactored to invoke `Invoke-Gh` internally rather than calling `& gh` directly. All existing behavior preserved: `-Paginate` flatten, `-AllowNotFound` silent-404, empty-204 short-circuit, `-Body` accepting `string[]` (normalized inside `Invoke-Gh`).
- Add `docs/adr/0006-private-invoke-gh-wrapper.md`: Context (agent-facing module, direct `& gh` in every public function meant ADR-4 was convention-enforced, not structural; testability required per-function mocking; return-shape drift between callers). Decision (single private `Invoke-Gh` wrapper with structured `[pscustomobject]` output). Consequences (one more layer of indirection; direct `& gh` in `Public/` is now a review-reject; Pester tests mock `Invoke-Gh` uniformly).
- Pester tests for both:
  - `Invoke-Gh`: preference isolation (caller sets `$PSNativeCommandUseErrorActionPreference = $true` → wrapper still returns exit code, does not throw); `string[]` `-StandardInput` normalization; return-shape assertions; non-zero exit code surfaced but not thrown.
  - `Invoke-GhApi`: `-Paginate` flatten, silent-404 with `-AllowNotFound`, empty-204 short-circuit, `-Body` `string[]` normalization, verifies `Invoke-Gh` is called (via `Mock`) with the expected argument shape.
- Update manifest `FunctionsToExport` to include `Invoke-GhApi` (only; `Invoke-Gh` is private).

### PR-C — `New-GhBody` + tests

- Implement `New-GhBody -Text -ScriptBlock` per D4. Cleanup in `finally`. Explicitly ensure cleanup runs even when the `ScriptBlock` throws.
- Enforce paragraph-per-line at input (reject multi-line paragraphs with a clear error, or reflow — decision deferred to ADR-0002 draft).
- Pester tests: normal flow, `ScriptBlock`-throws-still-cleans-up, empty body, multi-paragraph body, verify temp file is inside `[IO.Path]::GetTempPath()` and gone after invocation.

### PR-D — `Test-GhAuthScope` + tests

- Extract the `gh auth status`-parsing logic from `PS-MCS/gh-org` (see D2 resolution). No single canonical source — the pattern is generalized across three near-identical reconciler copies.
- Generalize: `Test-GhAuthScope -RequiredScope 'workflow','admin:org'` — asserts all listed scopes are present; emits `Write-Error -ErrorAction Stop` with the concrete `gh auth refresh -h github.com -s <missing>` remediation when any are missing. Invokes `gh auth status` through `Invoke-Gh`.
- Pester tests: mocked `Invoke-Gh` output covering (a) all scopes present, (b) one missing, (c) not logged in, (d) unexpected output shape.

### PR-E — `Resolve-GhCommitSha` + v0.1.0 tag

- Implement `Resolve-GhCommitSha -Owner -Repo -Ref [-CrossCheck]`. Default path: `Invoke-GhApi "repos/$Owner/$Repo/commits/$Ref"` → `.sha`.
- `-CrossCheck`: additionally fetch `git/refs/tags/$Ref` and warn if `.object.sha` disagrees with the commits path.
- Pester tests with mocked `Invoke-GhApi` covering: lightweight tag (both agree), annotated tag (disagree → warning), branch, commit SHA, missing ref.
- Update `README.md` with the full function list.
- Bump manifest to `0.1.0`, tag `v0.1.0` on merge, close issue #1.

## Follow-on work — tracked separately from #1

- Migrate `PS-MCS/gh-org` reconcilers to consume `PS.GitHub`: delete `common/Invoke-GhApi.ps1`, add `#Requires -Modules PS.GitHub` + `Import-Module PS.GitHub` in each script's `Begin{}`, update reconciler workflows to `Install-Module -Path` the module during CI. Separate PR against `gh-org` after `v0.1.0` ships.
- Revisit PSGallery publish once one external consumer needs it.

## Conventions and reference files (author-time)

- PowerShell authoring: `c:\Users\just9539\.agents\skills\powershell\SKILL.md` (`references/module-structure.md`, `references/advanced-functions.md`, `references/pester-testing.md`).
- `gh` / JSON CLI patterns: `c:\Users\just9539\.agents\skills\pwsh-cli-json\SKILL.md`.
- Terminal / body-authoring hygiene: `c:\Users\just9539\AppData\Roaming\Code\User\prompts\pwsh-terminal.instructions.md`.
- Workflow security: `c:\Users\just9539\.agents\skills\github-actions-security\SKILL.md`.
- ADR format: `c:\Users\just9539\.agents\skills\adr\SKILL.md`.
