# AGENTS.md — repo conventions for `PS.GitHub`

This file gives an AI agent (or a human working alongside one) enough context to
work productively in this repo without re-reading the umbrella issue or every
skill file from scratch.

**Read first:**

- [`docs/adr/`](docs/adr/) — architecturally significant decisions. Start here for "why is it this way?" questions.
- [Umbrella tracking issue #1](https://github.com/johnsarie27/PS.GitHub/issues/1) — historical: the design rationale that motivated the module (pain points, shape decisions, what was rejected and why). Closed 2026-07-02 when v0.1.0 shipped.

## Purpose

`PS.GitHub` is a small, portable PowerShell module of helpers wrapping the `gh`
CLI and GitHub REST API. It is deliberately narrow: it targets recurring
mistakes that always-on VS Code instructions and author-time skills cannot
prevent because those mistakes involve **stateful side effects that outlive
the author's attention span** (temp-body-file litter, missing OAuth scopes
surfacing as opaque HTTP 404s, tag-object vs commit-SHA confusion when pinning
GitHub Actions).

The module's primary consumer is AI-agent-driven workflows, not humans typing at
a REPL. Function shapes should make correct usage the easiest usage — cleanup
is not the caller's job; preflight failure produces a copy-paste remediation
string; endpoint shape is not something the caller has to remember.

## v0.1.0 function inventory

### Public functions (exported via manifest)

| Function | Status | Purpose |
|---|---|---|
| `Invoke-GhApi` | ported (PR-B) | Foundation `gh api` wrapper: pagination flatten, silent-404, empty-204 short-circuit. Delegates to the private `Invoke-Gh` for the actual `gh` invocation. |
| `New-GhBody` | implemented (PR-C) | Authored-body handling. `-ScriptBlock` wrapper shape: writes body to a temp file, invokes the block with the path (plus any `-ArgumentList` values), cleans up in `finally` even on exception. Paragraph handling is convention-only per ADR-7. Rejects `$using:` in `-ScriptBlock` before writing the temp file; caller variables are already in scope directly (ADR-9). |
| `Test-GhAuthScope` | implemented (PR-D) | Parses `gh auth status 2>&1` (via `Invoke-Gh`), asserts required OAuth scopes are present, emits the exact `gh auth refresh -h github.com -s <scope>` remediation on miss. Uses exact scope-list comparison (not substring regex) so `admin` cannot false-match `admin:org`. |
| `Resolve-GhCommitSha` | implemented (PR-E) | Tag/branch/SHA → commit SHA via `GET /repos/{o}/{r}/commits/{ref}` (avoids the annotated-tag-object trap). Optional `-CrossCheck` warns on disagreement with `/git/refs/tags/{tag}`. |
| `New-GhSignedCommit` | implemented (#19) | Creates a single GitHub-**signed** commit via the GraphQL `createCommitOnBranch` mutation. **Replaces** the head branch with one commit off the base tip; prior commits on it are discarded. The commit is staged on a throwaway `ps-github/tmp/<guid>` ref and the head branch is then moved to it in a single ref update, so the head branch is never momentarily equal to base and no open PR is auto-closed (ADR-10, #29). Promoted from `PS-MCS/gh-org`'s `New-SignedCommitOnBranch`; decoupled from cwd (`-Addition` takes `Content`/`LiteralPath`), supports multiple `additions[]`/`deletions[]`, and pins UTF-8 via `New-GhBody` + `gh api graphql --input <file>`. REST calls route through `Invoke-GhApi`, the GraphQL call through `Invoke-Gh`. |
| `Get-GhTokenExpiration` | implemented (#20) | Probes `gh api /user --include`, parses the `github-authentication-token-expiration` header, and returns a side-effect-free object `{ HasExpiration; ExpiresAt; DaysRemaining }`. Deterministic core split out of `PS-MCS/gh-org`'s `Test-PatExpiration`; the CI presentation (`Write-Warning` / `GITHUB_STEP_SUMMARY` / `exit 0`) deliberately stays in gh-org. Throws on probe failure or an unparseable header; an absent header is `HasExpiration = $false`. |

### Private helpers (dot-sourced, not exported)

| Helper | Status | Purpose |
|---|---|---|
| `Invoke-Gh` | implemented (PR-B) | Lowest-level `gh` wrapper, modeled on `johnsarie27/PS.DCU/Private/Invoke-DCU.ps1`. Structural enforcement of ADR-4 (`$PSNativeCommandUseErrorActionPreference = $false` in exactly one place) and `string[]` normalization at the boundary. Every public function that invokes `gh` goes through it; direct `& gh` in `Public/` is a review-reject. See ADR-6. |

Status is tracked in `FunctionsToExport` in [PS.GitHub.psd1](PS.GitHub.psd1) —
the manifest is the authoritative list of what is actually **exported**
(only public functions).

## Cross-cutting rules every public function honors

These are non-negotiable and encoded in ADRs where they warrant one. Any PR
that violates them should be flagged in review.

1. **`$PSNativeCommandUseErrorActionPreference` isolation.** Enforced
   structurally by the private `Invoke-Gh` helper (ADR-6) so a caller
   with strict native-error handling cannot turn the `& gh` +
   `$LASTEXITCODE` pattern into a `NativeCommandExitException`. Direct
   `& gh` calls in `Public/` are a review-reject. See
   `docs/adr/0004-native-command-preference-isolation.md` for the rule
   and `docs/adr/0006-private-invoke-gh-wrapper.md` (PR-B) for the
   structural enforcement mechanism.
2. **`string[]` normalization at the boundary.** Any `-Body` / `-Text`
   parameter runs through `Out-String` / `-join "``n"` inside
   `Invoke-Gh` before being passed to a typed `[System.String]` `gh`
   argument. `string[]` capture from native output (e.g.
   `git show HEAD:path`, `gh issue view -q .body`) is a common source of
   `Cannot convert value to type System.String` errors.
3. **No `--jq` / `--query` for filter/project.** The module returns
   deserialized objects; callers use the pwsh pipeline
   (`ConvertFrom-Json` / `Where-Object` / `Select-Object`). `-Paginate`
   delegates to `gh --paginate` and pipes the merged array straight to
   `ConvertFrom-Json`; no flatten step is needed or present.
4. **Temp-body lifecycle is never the caller's problem.** `New-GhBody`
   owns creation and disposal end-to-end via the `-ScriptBlock` wrapper
   shape. Return-path + explicit-cleanup was considered and rejected —
   see `docs/adr/0002-scriptblock-wrapper-for-body-lifecycle.md`.
5. **Never write `$using:` inside a `New-GhBody -ScriptBlock`.** The
   block runs in the caller's own session state, not a remoting context,
   so `$using:` is invalid there and `New-GhBody` rejects it before
   writing the temp file. Reference caller variables directly, or pass
   them explicitly via `-ArgumentList` — see
   `docs/adr/0009-new-ghbody-using-guard-and-argumentlist.md`.

## Layout

```text
PS.GitHub/
  .devcontainer/         devcontainer + Dockerfile (installs gh CLI)
  .github/
    workflows/ci.yml     Pester + PSScriptAnalyzer, matrix on ubuntu + windows + macos
    workflows/release.yml   fires on `v*.*.*` tag push; creates GitHub Release with .zip artifact
    release.yml          auto-generated-release-notes categorization by PR label
    dependabot.yml
    CODEOWNERS
  .vscode/               editor settings + PSScriptAnalyzer rules
  Build/                 PSake harness (build.ps1 -> build.psake.ps1)
  Public/                one .ps1 per exported function, Verb-Noun.ps1
  Private/               internal helpers, NOT exported
  Tests/                 Pester tests, Tests/Unit/<Function>.tests.ps1
  docs/
    adr/                 architectural decision records
  PS.GitHub.psd1         module manifest (authoritative export list)
  PS.GitHub.psm1         module loader (dot-sources Public/ + Private/)
  README.md              user-facing quickstart + function list
  CONTRIBUTING.md        new-function checklist + template
  LICENSE
  AGENTS.md              this file (single source of truth for agent conventions)
```

## Working conventions

### Branching + PR flow

- One PR per function or per cross-cutting concern. Historical example: v0.1.0 shipped as five PRs (scaffold, then one per function), tracked under closed issue #1.
- Branches: `<issue-number>-<short-slug>` (e.g. `1-scaffold-adrs-ci`, `7-fix-paginate-flatten`).
- Every PR references the tracking issue with `(refs #N)`. The final PR of a group uses `Closes #N`.
- Commit messages follow the user's convention: action + scope in the subject, multi-paragraph rationale in the body when non-trivial.

### Function authoring

New functions land under `Public/<Verb-Noun>.ps1` matching the function name.
Every function has:

- Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.INPUTS`,
  `.OUTPUTS`, `.EXAMPLE`, `.NOTES`).
- A `.NOTES` `Status:` line — one of `Stable`, `Beta`, `Experimental`,
  `Deprecated`.
- Only approved PowerShell verbs.
- A Pester test at `Tests/Unit/<Verb-Noun>.tests.ps1`.
- The function name added to `FunctionsToExport` in the manifest.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full checklist and template.

## Referenced skills

- `powershell` skill — PowerShell module + function + Pester conventions.
  `~/.agents/skills/powershell/SKILL.md` plus the
  `references/module-structure.md`, `references/advanced-functions.md`,
  `references/pester-testing.md` files.
- `pwsh-cli-json` skill — `gh` / JSON CLI patterns, one-paragraph-per-line rule
  for GitHub bodies.
  `~/.agents/skills/pwsh-cli-json/SKILL.md`.
- `github-actions-security` skill — third-party action SHA pinning, minimum
  `permissions:`, concurrency, timeouts.
  `~/.agents/skills/github-actions-security/SKILL.md`.
- `adr` skill — ADR format and when to write one.
  `~/.agents/skills/adr/SKILL.md`.
