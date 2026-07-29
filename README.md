# PS.GitHub

[![ci](https://github.com/johnsarie27/PS.GitHub/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/johnsarie27/PS.GitHub/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.4%2B-blue?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![GitHub release](https://img.shields.io/github/v/release/johnsarie27/PS.GitHub)](https://github.com/johnsarie27/PS.GitHub/releases/latest)

Portable PowerShell helpers wrapping the [`gh` CLI](https://cli.github.com/)
and the [GitHub REST API](https://docs.github.com/rest). Deliberately narrow:
the module targets a curated set of recurring pain points that always-on
author-time guidance cannot prevent, because the mistakes involve stateful
side effects that outlive the author's attention span.

**Status:** v0.1.0 shipped 2026-07-02. See the [ADRs](docs/adr/) for architectural decisions and the closed [tracking issue #1](https://github.com/johnsarie27/PS.GitHub/issues/1) for the original design rationale.

## What it prevents

| Class of mistake | Helper |
|---|---|
| Orphaned temp body files after `gh --body-file` writes | `New-GhBody` (`-ScriptBlock` wrapper — cleanup impossible to forget) |
| Missing OAuth scopes surfacing as opaque HTTP 404s on `.github/workflows/*`, org-roles, or security-configuration writes | `Test-GhAuthScope` (preflight with exact remediation string on miss) |
| Tag-object SHA vs. commit SHA confusion when pinning GitHub Actions | `Resolve-GhCommitSha` (`/commits/{ref}` by default; `-CrossCheck` warns on disagreement) |
| Unsigned CI commits rejected by a verified-signature ruleset | `New-GhSignedCommit` (GitHub-signed commit via GraphQL `createCommitOnBranch`; single clean commit off the base tip) |
| Native-command exit handling, silent 404 for optional resources, empty 204 short-circuit, pagination flatten, `string[]` boundary normalization | `Invoke-GhApi` (foundation wrapper used by the other three) |

Explicit non-goals are documented in
[`docs/adr/0003-rejected-function-scope.md`](docs/adr/0003-rejected-function-scope.md).

## Requirements

- PowerShell **7.4** or later (Core edition).
- The `gh` CLI on `PATH`, authenticated via `gh auth login`. Scope
  requirements are endpoint-specific and enforced by `Test-GhAuthScope` at
  the point of use.

## Install (v0.1.0)

`v0.1.0` is a git-tag-only release; there is no PSGallery publish yet.
There are two install paths.

**Preferred (with [`SecurityTools`](https://github.com/johnsarie27/SecurityTools)):**
`Install-GitHubModule` consumes the release-workflow output directly —
it fetches the latest release, downloads the `PS.GitHub-vX.Y.Z.zip` asset,
extracts it to your module path, and unblocks the files:

```powershell
# Requires SecurityTools:
# https://github.com/johnsarie27/SecurityTools
Install-GitHubModule -Account 'johnsarie27' -Repository 'PS.GitHub'
```

**Manual (without SecurityTools):** install by path from a clone:

```powershell
git clone https://github.com/johnsarie27/PS.GitHub.git
Install-Module -Path ./PS.GitHub -Scope CurrentUser -Force
# or, for a single-shot import without site-wide install:
Import-Module ./PS.GitHub/PS.GitHub.psd1
```

In CI (GitHub Actions), the equivalent is:

```yaml
- uses: actions/checkout@... # your consumer repo
- uses: actions/checkout@... # PS.GitHub, checked out to ./PS.GitHub
  with:
    repository: johnsarie27/PS.GitHub
    ref: v0.1.0
    path: PS.GitHub
- shell: pwsh
  run: Import-Module ./PS.GitHub/PS.GitHub.psd1
```

## Quickstart

Once `v0.1.0` is tagged, the functions are usable like this:

```powershell
# Wrapped gh api with silent-404 and pagination flatten.
$repos = Invoke-GhApi -Path 'orgs/my-org/repos' -Paginate

# Author a GitHub body without hard-wrapping and without leaking temp files.
$body = @(
    'First paragraph. This will wrap in GitHub UI on its own; do not hard-wrap in source.'
    ''
    'Second paragraph.'
) -join "`n"

New-GhBody -Text $body -ScriptBlock {
    param($path)
    gh issue create --repo my-org/my-repo --title 'Example' --body-file $path
}

# Preflight OAuth scope before a write that would 404 without it.
Test-GhAuthScope -RequiredScope 'workflow'

# Resolve a tag to a commit SHA for Actions pinning.
$sha = Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3

# Write a GitHub-signed commit (satisfies a verified-signature ruleset).
$commit = @{
    NameWithOwner = 'my-org/my-repo'
    BaseBranch    = 'main'
    HeadBranch    = 'automation/baseline'
    Headline      = 'chore(baseline): refresh (auto)'
    Addition      = @{ Path = 'baseline/data.json'; LiteralPath = './data.json' }
}
$oid = New-GhSignedCommit @commit
```

## Cross-cutting behavior

Every public function honors four rules — see
[`AGENTS.md`](AGENTS.md#cross-cutting-rules-every-public-function-honors)
for the full statement and rationale:

1. Isolates `$PSNativeCommandUseErrorActionPreference` inside its own scope
   so a caller with strict native-error handling cannot short-circuit the
   wrapper's exit-code logic.
   ([ADR 4](docs/adr/0004-native-command-preference-isolation.md))
2. Normalizes `string[]` input to a single `string` at the boundary so
   `git show` / `gh view -q .body` capture patterns work.
3. Does not use `--jq` / `--query` for filter/project — callers receive
   deserialized objects and use the pwsh pipeline.
4. Owns temp-body lifecycle end-to-end — see
   [ADR 2](docs/adr/0002-scriptblock-wrapper-for-body-lifecycle.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the new-function checklist and
function template. New functions require Pester tests, comment-based help
with a `.NOTES Status:` line, and an entry in `FunctionsToExport` in
[`PS.GitHub.psd1`](PS.GitHub.psd1).

## License

[MIT](LICENSE).
