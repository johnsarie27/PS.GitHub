function New-GhBody {
    <#
    .SYNOPSIS
        Write a GitHub issue/PR/comment body to a temp file and invoke a caller-supplied ScriptBlock with the path, cleaning up on scope exit.
    .DESCRIPTION
        Solves the "orphaned temp body file" hygiene miss that `gh` commands
        taking `--body-file <path>` (e.g. `gh issue create`, `gh pr create`,
        `gh issue comment`, `gh pr edit`) create when the caller forgets to
        delete the temp file after use, especially in error paths.

        The function:

          1. Normalizes `-Text` (accepts `string` or `string[]`; `string[]`
             is joined with `` `n ``).
          2. Writes the normalized body to a fresh temp file under
             `[System.IO.Path]::GetTempPath()`.
          3. Rejects a `-ScriptBlock` containing a `$using:` reference
             before any temp file is written (invalid outside remoting
             contexts; see `.PARAMETER ScriptBlock`).
          4. Invokes the caller's `-ScriptBlock`, passing the temp-file
             path as its first positional argument, followed by any
             `-ArgumentList` values supplied.
          5. **Always** deletes the temp file in `finally`, even if the
             `ScriptBlock` throws. The caller cannot leak the file.
          6. Returns whatever the `ScriptBlock` returns (transparent
             passthrough).

        See [ADR-2](../docs/adr/0002-scriptblock-wrapper-for-body-lifecycle.md)
        for the wrapper-shape decision, [ADR-7](../docs/adr/0007-new-ghbody-paragraph-convention.md)
        for the paragraph-handling behavior (convention only; no runtime
        reflow or rejection), and [ADR-9](../docs/adr/0009-new-ghbody-using-guard-and-argumentlist.md)
        for the `$using:` guard and `-ArgumentList`.

        Caller convention: prefer passing `-Text` as a `string[]` with one
        paragraph per element and empty strings for paragraph breaks.
        GitHub renders `` `n `` inside a paragraph as a visible line break,
        so hard-wrapping a paragraph across multiple non-blank lines
        produces ragged output on the rendered issue/PR page.
    .PARAMETER Text
        The body content. Accepts `string` or `string[]`. A `string[]` is
        joined with `` `n `` (one element per line of the body). An
        empty-string element produces a blank line, encoding a paragraph
        break in GitHub's rendered output.
    .PARAMETER ScriptBlock
        The block to invoke with the temp-file path. The block runs in the
        caller's session state (not a new scope, not a remoting session),
        so caller variables -- including loop variables -- are already
        directly accessible inside it by name. Do not use `$using:`: that
        syntax is valid only in remoting contexts (`Invoke-Command` against
        a session, `Start-Job`, `InlineScript`) and fails at invoke time
        here with a non-terminating error. `New-GhBody` rejects a
        `ScriptBlock` containing `$using:` before any temp file is written;
        see `-ArgumentList` for the sanctioned way to pass values in
        explicitly (e.g. from inside a `foreach`, where a plain variable
        reference can also be captured with `.GetNewClosure()`).
    .PARAMETER ArgumentList
        Optional extra positional arguments appended after the temp-file
        path when invoking `-ScriptBlock`. Use this to pass loop or context
        variables into the block explicitly instead of relying on closure
        capture or (incorrectly) `$using:`. Additive: omit it and the block
        is invoked with just the temp-file path, as before.
    .INPUTS
        None.
    .OUTPUTS
        Whatever the `-ScriptBlock` returns.
    .EXAMPLE
        PS C:\> $body = @(
        >>     'First paragraph. Renders as one flowing block regardless of source shape.'
        >>     ''
        >>     'Second paragraph.'
        >> )
        PS C:\> New-GhBody -Text $body -ScriptBlock {
        >>     param($path)
        >>     gh issue create --repo my-org/my-repo --title 'Example' --body-file $path
        >> }

        Creates the issue with a two-paragraph body; the temp file is
        deleted in `finally` even if `gh issue create` throws.
    .EXAMPLE
        PS C:\> New-GhBody -Text $largeBody -ScriptBlock {
        >>     param($path)
        >>     gh pr edit 42 --repo my-org/my-repo --body-file $path
        >>     gh pr comment 42 --repo my-org/my-repo --body-file $path
        >> }

        Runs multiple `gh` calls against the same body file; both share
        the same temp file which is deleted once when the `ScriptBlock`
        returns.
    .EXAMPLE
        PS C:\> foreach ($n in $ids) {
        >>     New-GhBody -Text $body -ArgumentList $n -ScriptBlock {
        >>         param($path, $issueNumber)
        >>         gh issue comment $issueNumber --body-file $path
        >>     }
        >> }

        Passes the loop variable `$n` in explicitly via `-ArgumentList`
        rather than relying on `.GetNewClosure()` or (incorrectly)
        `$using:`.
    .NOTES
        Status: Stable
        - Temp-file lifecycle is guaranteed by the `try` / `finally` inside
          the function. The caller cannot forget to clean up because
          disposal is inside the wrapper.
        - Written with UTF-8 encoding without BOM (matches `gh --body-file`
          expectations across platforms).
        - No paragraph-per-line reflow or rejection (ADR-7). Caller is
          responsible for authoring the body in the shape they want
          rendered.
        - `$using:` is invalid inside `-ScriptBlock` (it is not a remoting
          context) and is rejected up front, before any temp file is
          written. Reference caller variables directly, or pass them via
          `-ArgumentList`. See ADR-9.
        - `SupportsShouldProcess` with `ConfirmImpact = 'Low'`: `-WhatIf`
          skips the whole operation (no temp file, no ScriptBlock invoked)
          and prints a "What if" line; `-Confirm` never fires unless the
          caller explicitly passes it (default `$ConfirmPreference = 'High'`
          in every mainstream PS session, including CI runners).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.Object])]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Body content (string or string[]).')]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [System.String[]] $Text,

        [Parameter(Mandatory, HelpMessage = 'ScriptBlock invoked with the temp-file path as its single positional argument.')]
        [ValidateNotNull()]
        [System.Management.Automation.ScriptBlock] $ScriptBlock,

        [Parameter(HelpMessage = 'Extra positional arguments appended after the temp-file path when invoking -ScriptBlock.')]
        [System.Object[]] $ArgumentList = @()
    )
    Begin {
        Write-Verbose -Message ('Starting {0}' -f $MyInvocation.MyCommand)
    }
    Process {
        # $using: is only meaningful in remoting contexts (Invoke-Command
        # against a session, Start-Job, InlineScript). -ScriptBlock runs
        # in-process in the caller's own session state via `&`, so a
        # $using: reference here parses fine but fails at invoke time with
        # a non-terminating error -- easy to miss unless the caller has
        # $ErrorActionPreference = 'Stop'. Reject it up front, before the
        # temp file is created, and name the offending variable(s) so the
        # fix is obvious. See issues #16 and #23, ADR-9.
        $usingRefs = $ScriptBlock.Ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.UsingExpressionAst] }, $true)

        if ($usingRefs) {
            # SubExpression is only a bare VariableExpressionAst for the
            # simple `$using:var` form. For `$using:obj.Property` or
            # `$using:hash['key']`, the using expression wraps just the
            # root variable and a member/index access sits on top of it,
            # so SubExpression is a MemberExpressionAst/IndexExpressionAst
            # instead -- walk it to find the underlying variable name(s).
            $names = $usingRefs.SubExpression.FindAll(
                { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true
            ).VariablePath.UserPath | Sort-Object -Unique
            $usingMessageTemplate = 'ScriptBlock contains $using: reference(s): {0}. The block runs in the ' +
                'caller''s own session state (not a remoting context), so reference these variables ' +
                'directly, or pass them via -ArgumentList.'
            Write-Error -Message ($usingMessageTemplate -f ($names -join ', ')) -ErrorAction Stop
        }

        # ADR-7: no reflow, no rejection. Join string[] with `n verbatim.
        # Callers wanting paragraph-per-line semantics author their input
        # in that shape; the API does not enforce it.
        $normalized = $Text -join "`n"

        # -WhatIf / ShouldProcess gate. Under -WhatIf, ShouldProcess returns
        # $false: skip both the temp file creation and the ScriptBlock
        # invocation entirely. The "What if:" line PowerShell prints uses
        # the target/operation strings supplied below.
        if (-not $PSCmdlet.ShouldProcess('temp body file', 'Write body to disk and invoke caller ScriptBlock')) {
            return
        }

        # Fresh temp file under the OS's temp path. GetTempFileName creates
        # a zero-byte file with a unique name; we overwrite it. UTF-8
        # without BOM (Set-Content -Encoding utf8 in PowerShell 7 defaults
        # to no-BOM, which matches gh --body-file expectations across
        # Windows, Linux, and macOS).
        $tempPath = [System.IO.Path]::GetTempFileName()
        Write-Verbose -Message ('Temp body file: {0}' -f $tempPath)

        try {
            # -NoNewline: the trailing `n from the join is the sole
            # newline handling; do not add another one.
            Set-Content -LiteralPath $tempPath -Value $normalized -Encoding utf8 -NoNewline

            # Invoke the caller's ScriptBlock with the temp path as its
            # first positional argument, followed by any -ArgumentList
            # values the caller supplied. Return the block's output
            # transparently.
            & $ScriptBlock $tempPath @ArgumentList
        }
        finally {
            # Guaranteed cleanup, even if the ScriptBlock throws.
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
