# ADR 2: ScriptBlock Wrapper for `New-GhBody` Temp-File Lifecycle

## Status

Accepted

## Context

Several `gh` subcommands accept a body via `--body-file <path>` instead of
`--body <string>` (e.g. `gh issue create`, `gh pr create`, `gh issue
comment`, `gh pr edit`). Callers write the body to a temporary file, pass
the path to `gh`, and are then responsible for deleting the file.

Two observed failure modes motivate a helper:

- **Orphaned temp files.** In practice callers forget to delete the temp
  file, especially when the `gh` call throws or the workflow is interrupted.
  Repositories accumulate files under `.git/info/` or the workspace root
  that were never cleaned up. The repository owner has flagged this
  explicitly as a "must-do" hygiene concern.

- **Hard-wrapped body text.** PowerShell here-strings authored in
  80-column source code tend to be hard-wrapped at the source, which
  renders as ragged mid-paragraph line breaks in GitHub's proportional-width
  columns. GitHub already wraps bodies itself; hard-wrapping the source
  fights that.

PowerShell has no native `using` block for arbitrary resources — no
guaranteed disposal short of `try` / `finally`. Three shapes for a helper
were considered:

- **A. Return-path + explicit `Remove-GhBody`.** The function returns a
  `[string]` path (or a wrapper object). The caller invokes the helper,
  passes the path to `gh`, and calls `Remove-GhBody` in a `finally` block.
  Ergonomic when it works; unforgiving when the caller forgets.

- **B. `ScriptBlock` wrapper.** The function takes a `-ScriptBlock`
  parameter and a `-Text` parameter. It writes the body to a temp file,
  invokes the block with the path as an argument, and deletes the file in
  its own `finally` block. The caller *cannot* forget to clean up because
  disposal is inside the wrapper.

- **C. Both shapes side by side.** Offer the wrapper as the recommended
  path and the return-path form for advanced use.

The module's primary consumer is AI-agent-authored automation, not a human
at an interactive REPL. Agents tend to forget cleanup steps in complex
control flow.

## Decision

We will implement `New-GhBody` as a **`ScriptBlock` wrapper only**. Its
signature is roughly:

```powershell
New-GhBody -Text $body -ScriptBlock { param($path) gh issue create --body-file $path ... }
```

The function creates a temp file with the (paragraph-per-line-normalized)
body content, invokes the caller's `ScriptBlock` with the path as its sole
argument, and deletes the temp file in a `finally` block that runs even
when the `ScriptBlock` throws. There is no return-path form.

## Consequences

Callers cannot forget to clean up. This eliminates the entire class of
orphaned-temp-file misses without requiring caller discipline.

Advanced patterns that would prefer a bare path (e.g. writing multiple
`gh` calls against the same body) are pushed toward one of two shapes:
call `New-GhBody` once with a `ScriptBlock` that runs all the `gh`
invocations; or write to a temp file directly and take on the cleanup
obligation manually. The module deliberately does not provide a
"return-path" convenience for the second case, because that convenience is
exactly what enables the miss.

The wrapper shape makes error semantics slightly less obvious. If the
`ScriptBlock` throws, the function's `finally` deletes the file but the
exception propagates. If the file write itself fails, no cleanup runs
because there is nothing to clean up. Callers wanting to inspect the temp
file for debugging must do so from *inside* the `ScriptBlock`, not after.

This decision supersedes any older pattern in `johnsarie27/ai` or
`PS-MCS/gh-org` where a bare temp-file path was returned and cleanup was
the caller's responsibility. Callers migrating to `PS.GitHub` refactor
their code into the `ScriptBlock` shape.
