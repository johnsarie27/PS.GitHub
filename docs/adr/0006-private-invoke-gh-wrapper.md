# ADR 6: Private `Invoke-Gh` Wrapper for Structural Cross-Cutting Rule Enforcement

## Status

Accepted

## Context

Two cross-cutting rules apply to every public function in `PS.GitHub` that
invokes `gh`:

- **`$PSNativeCommandUseErrorActionPreference` isolation.** Documented in
  [ADR-4](0004-native-command-preference-isolation.md). A caller who has
  set the preference to `$true` (as recommended by the powershell-authoring
  skill for strict operational scripts) will otherwise turn the `& gh` +
  `$LASTEXITCODE` inspection pattern into a `NativeCommandExitException`
  thrown by the call operator before the wrapper can see the exit code.
  Silent-404 handling, empty-204 short-circuit, and any other exit-code-aware
  behavior break in that case.
- **`string[]` -> `string` normalization at the boundary.** Callers
  frequently capture text via patterns like `$b = git show HEAD:path` or
  `$b = gh issue view N -q .body`, both of which return `string[]` (one
  element per line). Passing that `$b` directly to a typed `[System.String]`
  parameter throws `Cannot convert value to type System.String` under
  PowerShell's argument-transformation, and the resulting native-command
  call in `gh` fails with a confusing error message. Every function that
  accepts a body-shaped parameter has to normalize the input the same way.

In the initial PR-B draft of `Invoke-GhApi` (based on the direct port from
`PS-MCS/gh-org/common/Invoke-GhApi.ps1`), both rules were left to
individual public functions to remember. That worked for a single public
function but does not scale: `Test-GhAuthScope` (PR-D) also invokes `gh`
directly (as `gh auth status`), and any future function that shells out
to `gh` would need to re-encode both rules by convention.

The module's design premise, stated in issue #1 and reinforced throughout
the ADRs, is that its primary consumer is AI-agent-driven automation and
that **correct usage should be the easy usage**. Convention-enforced
cross-cutting rules are fragile: a new function author (human or agent)
may forget one or both, ship the function, and only discover the miss
when a strict caller trips over it in production. Structural enforcement
in a single place removes the miss possibility entirely.

Three shapes for enforcing these rules were considered:

- **A. Keep both as documented conventions.** Every public function that
  calls `gh` must set the preference and normalize `string[]` inputs
  before invocation. Fragile for the reasons above.

- **B. Extract each rule into its own helper.** For example
  `Push-GhPreference` / `Pop-GhPreference` and `ConvertTo-GhString`.
  Multiple choke points; the caller must remember to invoke each. Doesn't
  solve the "forget to invoke it" problem, only shifts it.

- **C. A single private `Invoke-Gh` wrapper.** All public functions call
  `gh` exclusively through this wrapper. Both rules are enforced inside
  the wrapper; direct `& gh` in `Public/` is a review-reject. Adds one
  layer of indirection but eliminates the class of miss.

The pattern in shape **C** mirrors
`johnsarie27/PS.DCU/Private/Invoke-DCU.ps1`, which serves the same purpose
for the Dell Command Update CLI in that module. `Invoke-DCU` uses
`Start-Process` because DCU's CLI benefits from process isolation; `gh`
streams cleanly through `& gh @Arguments 2>&1` and stdin pipes via
`--input -`, so the equivalent for this module is simpler and does not
need `Start-Process`.

## Decision

We will ship **`Private/Invoke-Gh.ps1`** as the single lowest-level `gh`
wrapper for the module. Its signature is:

```powershell
function Invoke-Gh {
    [OutputType([System.Management.Automation.PSCustomObject])]
    Param(
        [System.String[]] $Arguments,
        [System.String[]] $StandardInput  # optional; string or string[]
    )
    # returns [pscustomobject] @{ ExitCode; Output; Arguments; Duration }
}
```

Inside the function:

- `$PSNativeCommandUseErrorActionPreference = $false` is set on entry.
- `-StandardInput` is normalized via `-join "``n"` regardless of shape.
- `$output = & gh @Arguments 2>&1` captures both stdout and stderr.
- The return object is a `[PSCustomObject]` with a stable shape.
- The function **never throws** on non-zero exit; it always returns the
  structured object. Interpretation (silent-404, empty-204, JSON parse)
  is the caller's responsibility.

Every public function in `PS.GitHub` that invokes `gh` calls it through
`Invoke-Gh`. Direct `& gh @args` in `Public/` is a review-reject and is
documented as such in `AGENTS.md`.

## Consequences

Positive:

- The two cross-cutting rules are enforced structurally, not by
  convention. A future public function author who forgets to normalize a
  body input still gets the normalization for free, because it happens
  inside `Invoke-Gh`.
- Pester tests for public functions (`Invoke-GhApi`, `Test-GhAuthScope`,
  etc.) can `Mock -CommandName Invoke-Gh` via the standard Pester
  mechanism because `Invoke-Gh` is a regular PowerShell function.
  Without this wrapper, testing every public function without invoking
  the real `gh` would require the awkward function-shadow-in-InModuleScope
  pattern for mocking native applications.
- The structured return shape (`ExitCode`, `Output`, `Arguments`,
  `Duration`) is uniform across callers; downstream telemetry or
  debugging can rely on it.

Negative:

- One more layer of indirection. Reading `Invoke-GhApi.ps1`, a reader
  must jump to `Invoke-Gh` to see the actual `& gh` call.
- Reuse is modest in v0.1.0: only `Invoke-GhApi` and `Test-GhAuthScope`
  will call the wrapper (`New-GhBody` invokes `gh` via the caller's
  `-ScriptBlock`; `Resolve-GhCommitSha` goes through `Invoke-GhApi`).
  If the module shipped just one public function, the wrapper would not
  pay for itself.
- The "no direct `& gh` in `Public/`" rule still has to be communicated
  and enforced in review. A contributor could still skip `Invoke-Gh` and
  call `& gh` inline in a public function; the wrapper does not
  physically prevent that, only makes it visible in code review.

Neutral:

- `Duration` telemetry is added but has no current caller. It costs
  approximately one `Get-Date` call per invocation. Kept because it is
  cheap and useful the first time we need to debug a slow `gh` call.
