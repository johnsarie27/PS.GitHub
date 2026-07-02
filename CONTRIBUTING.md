# Contributing Guide

- Minor fixes (typo, doc tweak) can go directly as a pull request.
- Substantive changes should start with a comment on an existing issue or a
  new issue on this repository. See
  [`docs/PLAN.md`](docs/PLAN.md) for the current v0.1.0 scope; if the change
  is out of scope for v0.1.0, we may defer it.
- **Focus each pull request on a single function or a single cross-cutting
  concern.** Big multi-function PRs are hard to review and hard to revert.

## Working conventions

- Branch off `main` using `<issue-number>-<short-slug>` (e.g.
  `1-scaffold-adrs-ci`, `12-fix-paginate-flatten`).
- Every commit that traces to an issue includes `(refs #N)` in the subject
  or body. Only the final commit of the last PR under an umbrella issue
  uses `closes #N`.
- Do not commit directly to `main`. All changes land through a PR that
  passes CI.
- Commit messages follow this shape: `action: scope`, then a blank line,
  then a rationale paragraph (or several) explaining *why*. Example:
  `docs: record 2026-07-01 preflight finding on D2 source path (refs #1)`.

## New Function Checklist

- Place the file under `Public/` (exported) or `Private/` (internal only).
- Name the file `Verb-Noun.ps1` matching the function name exactly.
- Use only [approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).
- Always include comment-based help (`.SYNOPSIS`, `.DESCRIPTION`,
  `.PARAMETER`, `.INPUTS`, `.OUTPUTS`, `.EXAMPLE`, `.NOTES`). The `.NOTES`
  block must include a `Status:` line using one of the following values:

  | Value | Meaning |
  | --- | --- |
  | `Stable` | Production-ready; fully tested and supported |
  | `Beta` | Functional but may have rough edges or limited testing |
  | `Experimental` | Early development; API or behavior may change |
  | `Deprecated` | Still works but will be removed in a future release |

- Add a Pester test under `Tests/Unit/Verb-Noun.tests.ps1`. Mock external
  side effects (`gh`, `Invoke-RestMethod`, `Get-Content`) so tests are
  hermetic and cross-platform.
- If the function is **exported**, add its name to `FunctionsToExport` in
  [`PS.GitHub.psd1`](PS.GitHub.psd1).
- Honor the four cross-cutting rules from
  [`AGENTS.md`](AGENTS.md#cross-cutting-rules-every-public-function-honors):
  isolate `$PSNativeCommandUseErrorActionPreference`, normalize `string[]`
  at the boundary, do not use `--jq`/`--query` for filter/project, and
  never leave the caller responsible for temp-file cleanup.
- Run `Analyze` and `Test` locally before opening the PR (see
  [Running the build locally](#running-the-build-locally)).

## Function Template

```powershell
function Verb-Noun {
    <#
    .SYNOPSIS
        One-line summary of what the function does.
    .DESCRIPTION
        Longer description of behavior, side effects, and intended use.
        Mention any cross-cutting behavior the function participates in
        (silent-404, pagination flatten, temp-body lifecycle, etc.).
    .PARAMETER Foo
        Description of the Foo parameter.
    .INPUTS
        System.String.
    .OUTPUTS
        System.Object.
    .EXAMPLE
        PS C:\> Verb-Noun -Foo 'bar'
        Explanation of what the example does.
    .NOTES
        Status: Beta
        Notes: Isolates $PSNativeCommandUseErrorActionPreference.
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param (
        [Parameter(Mandatory, HelpMessage = 'What Foo is for.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Foo
    )

    begin {
        $PSNativeCommandUseErrorActionPreference = $false
    }

    process {
        # Implementation.
    }
}
```

## Running the build locally

The build harness lives under [`Build/`](Build/) and wraps PSake. First-time
setup installs Pester, psake, and PSScriptAnalyzer:

```powershell
./Build/build.ps1 -ResolveDependency -TaskList Init
```

Then run the same tasks CI runs:

```powershell
./Build/build.ps1 -TaskList CombineFunctionsAndStage
./Build/build.ps1 -TaskList Analyze
./Build/build.ps1 -TaskList Test
```

`Staging/` and `Artifacts/` are gitignored — the harness rebuilds them each
run.

## Pull request checklist

Before requesting review:

- [ ] Function file follows the naming, placement, help-block, and
      `.NOTES Status:` conventions above.
- [ ] Pester tests exist and pass locally on your platform.
- [ ] `Analyze` passes locally (no PSScriptAnalyzer errors).
- [ ] `FunctionsToExport` in the manifest is updated for exported functions.
- [ ] Any body/message text the PR authors follows the
      one-paragraph-per-line convention (no hard-wrapping at 72–80 cols).
      This applies to PR descriptions and issue comments too, not just
      strings in code.
- [ ] Any architecturally significant decision (public interface,
      cross-cutting rule, dependency swap) is captured in a new ADR under
      [`docs/adr/`](docs/adr/) following the
      [ADR format](docs/adr/0001-dedicated-module-repository.md).
