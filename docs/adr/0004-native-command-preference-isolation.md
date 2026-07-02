# ADR 4: `$PSNativeCommandUseErrorActionPreference` Isolation Per Function

## Status

Accepted

## Context

PowerShell 7 introduced a preference variable,
`$PSNativeCommandUseErrorActionPreference`, that (when `$true`) causes the
call operator (`&`) to throw a `NativeCommandExitException` when a native
executable exits with a non-zero code. This is a useful strictness knob
for scripts that treat any native-command failure as fatal.

Every helper in `PS.GitHub` invokes `gh` as a native command with
`& gh ...` and inspects the result — either `$LASTEXITCODE`, or the output
captured via `2>&1`, or both. `Invoke-GhApi` in particular has a
deliberate `-AllowNotFound` mode that catches HTTP 404 responses (which
`gh api` surfaces as exit code 1) and returns `$null` instead of failing.
This "silent 404" behavior is a documented feature of the wrapper — it is
what makes optional-resource reads (like a repository's `CODEOWNERS` file
that may or may not exist) safe to attempt.

If a **caller** of any `PS.GitHub` function has set
`$PSNativeCommandUseErrorActionPreference = $true` in their own scope
(which is common in strict operational scripts), the preference is
inherited by the function call: `& gh` throws a
`NativeCommandExitException` before the wrapper ever reads `$LASTEXITCODE`.
The wrapper's silent-404 handling, empty-204 short-circuit, and any other
exit-code-aware behavior are all bypassed. The caller sees an exception
whose message does not mention the endpoint or the auth state — just that
`gh` exited non-zero.

This has been observed concretely: a GitHub Actions workflow set the
preference for the whole `run:` block per the powershell-authoring skill,
then invoked a reconciler script whose `Invoke-GhApi` was designed around
`$LASTEXITCODE`. Every optional-resource read broke.

Two shapes for resolving this were considered:

- **A. Document the incompatibility.** Tell callers they must set the
  preference back to `$false` before invoking `PS.GitHub` functions. This
  puts the burden of the workaround on every caller and is easily
  forgotten.

- **B. Isolate the preference inside each function.** Each public function
  sets the preference to `$false` at its own scope entry, so the caller's
  value is transparently overridden for the duration of the call and
  restored automatically when the function returns.

## Decision

We will **isolate** `$PSNativeCommandUseErrorActionPreference` inside every
public function of `PS.GitHub`. Each function's `Begin{}` (or top-of-body
for simple functions) contains:

```powershell
$PSNativeCommandUseErrorActionPreference = $false
```

Because this is a preference variable and PowerShell restores scoped
variables on function return, no `finally` cleanup is required — the
caller's value is preserved for the caller's next statement.

The `.NOTES` section of each function's comment-based help mentions this
behavior. The module manifest description references it. Callers who
need the preference respected inside a `PS.GitHub` call have no supported
path — they must invoke `gh` directly.

## Consequences

Callers can set `$PSNativeCommandUseErrorActionPreference = $true` in their
own scripts (as recommended by the powershell-authoring skill) without
breaking `PS.GitHub`'s exit-code-aware behavior. This makes the module
safe to consume from strict operational scripts and CI workflow `run:`
blocks that adopt the strict preference.

The tradeoff is that a caller who legitimately wants "any `gh` non-zero
exit throws" cannot get that behavior *through* a `PS.GitHub` function.
This is intentional: the wrapper deliberately catches specific exit codes
(404 for optional reads, 204 for empty responses) and translates them
into structured output. Bypassing that translation by re-raising the
exception would defeat the module's purpose.

The isolation is invisible to callers unless they read the source or the
`.NOTES` section. Someone debugging why a call is *not* throwing might be
briefly confused. The comment-based help mitigates this at author time;
the manifest description mitigates it at discovery time.

This ADR extends to all future public functions in the module. Any new
helper that invokes a native command must include the same isolation.
Reviewers reject PRs that omit it.
