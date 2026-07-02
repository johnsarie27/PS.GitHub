function Test-GhAuthScope {
    <#
    .SYNOPSIS
        Verify the gh CLI is authenticated and has the required OAuth scope(s), or throw with a copy-paste remediation.
    .DESCRIPTION
        Parses the output of `gh auth status` (invoked via the private
        `Invoke-Gh` wrapper) and asserts that every scope in `-RequiredScope`
        is present on the current token. On any failure, emits a
        `Write-Error -ErrorAction Stop` with a concrete remediation string.

        Motivating incident (referenced by ADR-3 and issue #1): writes to
        `.github/workflows/*` require the `workflow` OAuth scope. Without
        it, GitHub returns HTTP 404 -- indistinguishable from
        route-not-found or repo-not-found -- burning ~15 minutes per
        incident narrowing "repo-specific quirk" -> "body shape" -> "path
        prefix" -> "token scope". A cheap preflight at the start of a
        script that will write workflows converts that entire debug spiral
        into a single copy-paste remediation:

            gh auth refresh -h github.com -s workflow

        Failure modes covered:

          - `gh` is not authenticated (`gh auth status` exits non-zero):
            emits a `gh auth login` remediation.
          - `gh auth status` output does not contain a "Token scopes:"
            line: emits a diagnostic including the full output.
          - One or more `-RequiredScope` values are absent from the parsed
            token scope list: emits a concrete
            `gh auth refresh -h github.com -s <missing1>,<missing2>`
            command in the error message.

        Scope matching uses exact string comparison against the parsed
        scope list, not substring regex. This avoids the subtle bug where
        passing `admin` as a required scope would falsely match `admin:org`
        via `-notmatch 'admin'`.

        Convention note: `Test-*` verbs conventionally return `$true`/`$false`
        without throwing. This function deliberately throws on miss because
        its whole value proposition is preventing execution of a script that
        will fail confusingly downstream if the scope is absent. Precedent:
        `Test-ModuleManifest` throws on an invalid manifest.
    .PARAMETER RequiredScope
        The OAuth scope name(s) that must be present on the current `gh`
        token (e.g. `workflow`, `admin:org`, `read:packages`). Compared
        exactly against the parsed token scope list; substring matches do
        not count.
    .INPUTS
        None.
    .OUTPUTS
        System.Boolean. Returns `$true` when every required scope is
        present. On any miss the function throws a terminating error via
        `Write-Error -ErrorAction Stop`.
    .EXAMPLE
        PS C:\> Test-GhAuthScope -RequiredScope 'workflow'

        Assert `workflow` scope before a script that writes to
        `.github/workflows/*`. Passes silently and returns `$true`, or
        throws with `gh auth refresh -h github.com -s workflow` in the
        error message.
    .EXAMPLE
        PS C:\> Test-GhAuthScope -RequiredScope 'admin:org', 'workflow'

        Assert both scopes before a script that both writes workflow
        files and manages organization membership.
    .NOTES
        Status: Stable
        - Invokes `gh auth status` via the private `Invoke-Gh` helper.
          Inherits `$PSNativeCommandUseErrorActionPreference` isolation
          (ADR-4) and the structured `[pscustomobject]` return shape
          (ADR-6).
        - `gh auth status` writes to stderr on some versions of `gh`;
          `Invoke-Gh` merges stderr into `Output` via `2>&1`.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    Param(
        [Parameter(Mandatory, HelpMessage = 'OAuth scope name(s) that must be present.')]
        [ValidateNotNullOrEmpty()]
        [System.String[]] $RequiredScope
    )
    Begin {
        Write-Verbose -Message ('Starting {0}' -f $MyInvocation.MyCommand)
    }
    Process {
        # Ask gh for the current auth state. Invoke-Gh merges stderr into
        # Output (2>&1) so the "Token scopes:" line -- which gh writes to
        # stderr on some versions -- is captured either way.
        $result = Invoke-Gh -Arguments @('auth', 'status')
        $text = ($result.Output | Out-String)

        if ($result.ExitCode -ne 0) {
            $msg = 'gh CLI is not authenticated (gh auth status exit code: {0}). Run: gh auth login' -f $result.ExitCode
            Write-Error -Message $msg -ErrorAction Stop
        }

        # Locate the "Token scopes:" line. gh's output has one line per
        # host block; there is at most one authenticated token per host in
        # the default configuration this module targets.
        $scopesLine = @($text -split "`n") |
            Where-Object { $_ -match 'Token scopes:' } |
            Select-Object -First 1

        if (-not $scopesLine) {
            $msg = "Unable to locate 'Token scopes:' in gh auth status output. Full output:`n{0}" -f $text
            Write-Error -Message $msg -ErrorAction Stop
        }

        # Parse the scope list. Modern gh renders scopes as single-quoted
        # items separated by commas: `Token scopes: 'admin:org', 'workflow'`.
        # Older versions used a bare comma-separated list. Try quoted first;
        # fall back to the bare form.
        $quoted = [regex]::Matches($scopesLine, "'([^']+)'")
        if ($quoted.Count -gt 0) {
            $activeScopes = @($quoted | ForEach-Object { $_.Groups[1].Value })
        }
        else {
            # Everything after the first ':' is the scope list.
            $listPart = ($scopesLine -split ':', 2)[1]
            $activeScopes = @($listPart.Trim() -split ',\s*' | Where-Object { $_ })
        }

        # Compare requested vs active using exact string equality (via -in).
        # -notin against a $string[] is exact-match; substring collisions
        # like 'admin' matching 'admin:org' do not occur.
        $missing = @($RequiredScope | Where-Object { $_ -notin $activeScopes })

        if ($missing.Count -gt 0) {
            $refresh = 'gh auth refresh -h github.com -s ' + ($missing -join ',')
            $msg = 'gh CLI is missing required OAuth scope(s): [{0}]. Re-run: {1}' -f ($missing -join ', '), $refresh
            Write-Error -Message $msg -ErrorAction Stop
        }

        $true
    }
}
