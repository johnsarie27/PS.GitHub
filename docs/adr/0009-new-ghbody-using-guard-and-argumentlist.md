# ADR 9: `New-GhBody` `$using:` Guard and `-ArgumentList`

## Status

Accepted

## Context

[ADR-2](0002-scriptblock-wrapper-for-body-lifecycle.md) established that
`New-GhBody` invokes the caller's `-ScriptBlock` with `& $ScriptBlock
$tempPath`, in-process, in the caller's own session state. Two issues
independently reported the same foot-gun surfacing from that shape:

- **Issue #16** (2026-07-07): in a `foreach` loop posting per-issue
  comments, the caller reached for `$using:n` to get the loop variable
  into the block. `$using:` is only meaningful in remoting contexts
  (`Invoke-Command` against a session, `Start-Job`, `InlineScript`); here
  it is invalid, and the working alternative (`.GetNewClosure()` plus a
  plain variable reference) is easy to miss under time pressure.
- **Issue #23** (2026-08-24): an LLM agent calling the module wrote
  `$using:label` inside a `-ScriptBlock`, twice in one session. Because
  `$using:` is *syntactically* valid, the block parses fine and fails
  only at invoke time, with a **non-terminating** error
  (`InvalidOperation: A Using variable cannot be retrieved...`). Unless
  the caller has `$ErrorActionPreference = 'Stop'`, `New-GhBody` returns
  `$null` and the calling script continues past the failure. In the
  observed incident this silent continuation fed an empty `$url` into a
  downstream `gh` invocation, which itself failed in a confusing way
  (argument-count error), followed by a hardcoded status line that
  reported success for work that never ran. The `$using:` mistake was
  cheap; the silent cascade it triggered was not.

Both issues point at the same root cause (the mechanism-accurate but
consequence-silent `.PARAMETER ScriptBlock` wording) and propose
overlapping fixes. Taken together they ask for three things:

1. Documentation that states the consequence, not just the mechanism:
   reference caller variables directly; do not use `$using:`.
2. A way to pass values into the block that does not depend on closure
   capture at all, for callers (especially agents) who would rather pass
   arguments explicitly than reason about scope.
3. A decision on whether to reject `$using:` at invoke time, trading a
   small amount of defensive code for turning a silent, non-terminating
   failure into a loud, terminating, actionable one.

On (3): rejecting a pattern that experienced human callers rarely reach
for cuts against the module's "do not handle scenarios that cannot
happen" default. But the module's stated primary consumer (ADR-2's
Context, AGENTS.md) is AI-agent-authored automation, and issue #23's
incident is a concrete, reproducing case of exactly this scenario
happening, with a real downstream cost. The scenario is not hypothetical
for this module's actual usage pattern.

## Decision

`New-GhBody` adopts both a preflight guard and an additive parameter:

- **`$using:` guard.** Before `ShouldProcess` and before the temp file is
  created, `New-GhBody` walks the `-ScriptBlock`'s AST for
  `UsingExpressionAst` nodes. If any are found, it calls `Write-Error
  -ErrorAction Stop` naming the offending variable(s) and returns without
  touching disk. This runs even under `-WhatIf`: it is static analysis of
  the block's source, not a side effect, so there is nothing for `-WhatIf`
  to suppress.
- **`-ArgumentList`.** A new optional `[object[]]` parameter, default
  `@()`. Values supplied are appended after the temp-file path when
  invoking the block: `& $ScriptBlock $tempPath @ArgumentList`. Omitting
  it reproduces the exact previous invocation (`& $ScriptBlock $tempPath`),
  so existing callers and existing closure-based usage are unaffected.
- **Documentation.** `.PARAMETER ScriptBlock` now states the consequence
  ("reference these variables directly... do not use `$using:`") rather
  than only the mechanism. `.PARAMETER ArgumentList` documents the
  explicit-passing alternative. A new `.EXAMPLE` shows the `foreach` +
  `-ArgumentList` pattern from issue #16 directly. `.NOTES` cross-references
  this ADR.

The guard and `-ArgumentList` are independent fixes that compose: a
caller can keep using `.GetNewClosure()` (still supported, still the
right tool when the block genuinely needs a caller-scope closure over
several variables), or switch to `-ArgumentList` for the common
single-or-few-variable case, and either way a stray `$using:` fails fast
with a message naming the variable instead of failing silently at invoke
time.

## Consequences

Positive:

- The `$using:` failure mode changes from *silent, non-terminating,
  discovered downstream* to *loud, terminating, discovered immediately*
  with the offending variable name in the message. No temp file is
  created on the reject path, so there is no partial side effect to clean
  up.
- `-ArgumentList` gives callers (especially agents generating code without
  `.GetNewClosure()` in their working vocabulary) a way to pass values into
  the block that does not depend on PowerShell closure-capture semantics
  at all.
- Both changes are additive. No existing `-ScriptBlock` usage without
  `$using:` is affected; `-ArgumentList` defaults to `@()`, reproducing
  the prior call signature exactly.

Negative:

- The guard is defensive code for a mistake careful human callers rarely
  make, which is a real (accepted) departure from the module's usual bar
  for added logic. It is justified here by a concrete, reproducing
  incident (issue #23) rather than a hypothetical one, per ADR-8's
  determinism framing: preventing a silent non-terminating failure from
  reaching a stateful downstream `gh` call is itself a run-time
  invariant, not merely a documentation fact.
- The AST walk adds a small amount of work to every `New-GhBody` call.
  This is negligible relative to the temp-file I/O and `gh` invocation the
  function already performs, and runs once per call, not per line.

Neutral:

- This does not change `FunctionsToExport`; `New-GhBody`'s signature
  gains one optional parameter. Per the module's Major.Minor.Build
  convention, this ships as a Minor bump (new feature, no breaking
  change), not a Build/patch bump alone, because `-ArgumentList` is new
  surface area, not only a bug fix.
- If a future review finds that agents still reach for `$using:` despite
  the guard (e.g. because they retry blindly on the error rather than
  reading it), the natural next step is surfacing the same remediation
  text in the `pwsh-cli-json` skill so it is available at author time,
  before the call is ever made. That is additive to this ADR, not a
  supersession.
