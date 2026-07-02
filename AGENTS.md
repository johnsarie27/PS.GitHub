# AGENTS.md — repo conventions for `PS.GitHub`

This file gives an AI agent (or a human working alongside one) enough context to
work productively in this repo without re-reading the umbrella issue or every
skill file from scratch.

**Read first:**

- [docs/PLAN.md](docs/PLAN.md) — the current v0.1.0 build plan with locked
  decisions (D1–D8), function scope, PR sequence, and open unknowns. This is
  the execution doc; if it disagrees with anything below, `PLAN.md` wins until
  it is updated.
- [Umbrella tracking issue #1](https://github.com/johnsarie27/PS.GitHub/issues/1) —
  the design rationale (what pain points, what shape decisions, what was
  rejected and why). Historical; the plan supersedes any conflicting execution
  detail.
- [docs/adr/](docs/adr/) — architecturally significant decisions.

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
| `New-GhBody` | implemented (PR-C) | Authored-body handling. `-ScriptBlock` wrapper shape: writes body to a temp file, invokes the block with the path, cleans up in `finally` even on exception. Paragraph handling is convention-only per ADR-7. |
| `Test-GhAuthScope` | implemented (PR-D) | Parses `gh auth status 2>&1` (via `Invoke-Gh`), asserts required OAuth scopes are present, emits the exact `gh auth refresh -h github.com -s <scope>` remediation on miss. Uses exact scope-list comparison (not substring regex) so `admin` cannot false-match `admin:org`. |
| `Resolve-GhCommitSha` | not yet implemented | Tag/branch/SHA → commit SHA via `GET /repos/{o}/{r}/commits/{ref}` (avoids the annotated-tag-object trap). Optional `-CrossCheck` warns on disagreement with `/git/refs/tags/{tag}`. |

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
   (`ConvertFrom-Json` / `Where-Object` / `Select-Object`). The one
   internal `--jq '.[]'` use is inside `Invoke-GhApi -Paginate`'s
   flatten step.
4. **Temp-body lifecycle is never the caller's problem.** `New-GhBody`
   owns creation and disposal end-to-end via the `-ScriptBlock` wrapper
   shape. Return-path + explicit-cleanup was considered and rejected —
   see `docs/adr/0002-scriptblock-wrapper-for-body-lifecycle.md`.

## Layout

```text
PS.GitHub/
  .devcontainer/         devcontainer + Dockerfile (installs gh CLI)
  .github/
    workflows/ci.yml     Pester + PSScriptAnalyzer, matrix on ubuntu + windows + macos
    dependabot.yml
    CODEOWNERS
  .vscode/               editor settings + PSScriptAnalyzer rules
  Build/                 PSake harness (build.ps1 -> build.psake.ps1)
  Public/                one .ps1 per exported function, Verb-Noun.ps1
  Private/               internal helpers, NOT exported
  Tests/                 Pester tests, Tests/Unit/<Function>.tests.ps1
  docs/
    PLAN.md              v0.1.0 build plan
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

- One PR per function (see `docs/PLAN.md` PR-B through PR-E). Scaffold PRs
  (like PR-A) are permitted for cross-cutting infrastructure work.
- Branches: `<issue-number>-<short-slug>` (e.g. `1-scaffold-adrs-ci`).
- Every PR references issue #1 with `(refs #1)`. Only PR-E `closes #1`.
- Commit messages follow the user's convention: action + scope in the subject,
  multi-paragraph rationale in the body when non-trivial.

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

### Terminal + CLI hygiene

- Multi-statement pwsh with here-strings or non-idempotent `gh` writes goes to
  a temp `.ps1` under `.git/info/` (untracked); delete the temp file after the
  write succeeds. Never leave orphaned temp body files.
- GitHub issue/PR/comment bodies: **one paragraph per line**, never hard-wrap.
  GitHub renders in a proportional column and wraps itself; hard-wrapping
  produces ragged output.
- Use `gh api <path>` + `ConvertFrom-Json` + pwsh pipeline. No `--jq` /
  `--query` for filter/project.
- Before retrying a non-idempotent `gh` write on ambiguous output, query state
  (`gh issue list --search`, `gh pr list --search`) — truncated output is not
  evidence the command failed.

Canonical rules live in the user-scoped instructions file
`~/AppData/Roaming/Code/User/prompts/pwsh-terminal.instructions.md` and the
`pwsh-cli-json` skill; the notes here are for orientation.

## Referenced skills and instructions

- `powershell` skill — PowerShell module + function + Pester conventions.
  `c:\Users\just9539\.agents\skills\powershell\SKILL.md` plus the
  `references/module-structure.md`, `references/advanced-functions.md`,
  `references/pester-testing.md` files.
- `pwsh-cli-json` skill — `gh` / JSON CLI patterns, one-paragraph-per-line rule
  for GitHub bodies.
  `c:\Users\just9539\.agents\skills\pwsh-cli-json\SKILL.md`.
- `github-actions-security` skill — third-party action SHA pinning, minimum
  `permissions:`, concurrency, timeouts.
  `c:\Users\just9539\.agents\skills\github-actions-security\SKILL.md`.
- `adr` skill — ADR format and when to write one.
  `c:\Users\just9539\.agents\skills\adr\SKILL.md`.
- User-scoped instructions
  `c:\Users\just9539\AppData\Roaming\Code\User\prompts\guidelines.instructions.md`
  and
  `c:\Users\just9539\AppData\Roaming\Code\User\prompts\pwsh-terminal.instructions.md`.
