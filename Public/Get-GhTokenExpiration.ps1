function Get-GhTokenExpiration {
    <#
    .SYNOPSIS
        Probe the authenticated gh token and return its expiration as an object, with no side effects.
    .DESCRIPTION
        Returns the expiration of the token `gh` is currently authenticated
        with, computed from the `github-authentication-token-expiration` HTTP
        response header that GitHub returns on every API response when the
        requesting token has an expiration date set. Fine-grained and classic
        PATs both expose this header; OAuth tokens and `GITHUB_TOKEN` do not.

        This is the deterministic core extracted from `PS-MCS/gh-org`'s
        `Test-PatExpiration`. The presentation concerns of that script -- the
        `Write-Warning`, the `GITHUB_STEP_SUMMARY` block, and the forced
        `exit 0` -- are deliberately **not** promoted: they are
        Actions-coupled and belong in the workflow glue, not the module. This
        function has no side effects and writes nothing; the caller decides
        what to do with the returned object.

        The output object is:

          - `HasExpiration` [bool]     -- `$false` when the token exposes no
            expiration header (OAuth token / `GITHUB_TOKEN`).
          - `ExpiresAt`     [datetime] -- the UTC expiry instant, or `$null`
            when `HasExpiration` is `$false`.
          - `DaysRemaining` [int]      -- whole days until expiry (floored),
            or `$null` when `HasExpiration` is `$false`. May be negative if
            the token is already expired.

        Error semantics: a **probe failure** (`gh api /user` exits non-zero)
        and a **present-but-unparseable** expiration header both raise a
        terminating error, so "could not determine" stays distinct from
        "token has no expiry". Only a genuinely absent header is reported as
        `HasExpiration = $false`.

        The `gh` call routes through the private `Invoke-Gh` wrapper, which
        owns `$PSNativeCommandUseErrorActionPreference` isolation (ADR-4) and
        the structured exit-code return (ADR-6).
    .INPUTS
        None.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with keys `HasExpiration`,
        `ExpiresAt`, `DaysRemaining`.
    .EXAMPLE
        PS C:\> Get-GhTokenExpiration

        Returns e.g. `HasExpiration=$true; ExpiresAt=[datetime]'2027-06-17 17:43:34Z';
        DaysRemaining=412` for a PAT, or `HasExpiration=$false` with null
        `ExpiresAt`/`DaysRemaining` for a token without an expiry.
    .EXAMPLE
        PS C:\> $exp = Get-GhTokenExpiration
        PS C:\> if ($exp.HasExpiration -and $exp.DaysRemaining -le 30) {
        >>     Write-Warning ('Token expires in {0} days (on {1:yyyy-MM-dd}).' -f $exp.DaysRemaining, $exp.ExpiresAt)
        >> }

        The warn-within-N-days presentation lives in the caller (e.g. a
        workflow step), not in the module.
    .NOTES
        Status: Beta
        - Uses `gh api /user --include` to capture response headers.
          Requires the `gh` CLI on `PATH` and an authenticated session.
        - Promoted from `PS-MCS/gh-org`'s `Test-PatExpiration` under the
          incident-driven axis ([ADR-3](../docs/adr/0003-rejected-function-scope.md):
          three baseline workflows depend on it) and the determinism axis
          ([ADR-8](../docs/adr/0008-determinism-vs-knowledge-criterion.md):
          the `--include` header extraction plus threshold math is the
          composable-wrong core; the "which header / which token types"
          knowledge stays in the `pwsh-cli-json` skill and the CI
          presentation stays in gh-org). Graded `Beta`: a moderate, not
          strong, determinism case.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    Param()
    Begin {
        Write-Verbose -Message ('Starting {0}' -f $MyInvocation.MyCommand)
    }
    Process {
        # Cheap API call to elicit the expiration header. --include dumps the
        # response headers to stdout before the body; the body is ignored.
        $result = Invoke-Gh -Arguments @('api', '/user', '--include')
        if ($result.ExitCode -ne 0) {
            Write-Error -Message ('gh api /user probe failed (exit {0}): {1}' -f $result.ExitCode, ($result.Output | Out-String)) -ErrorAction Stop
        }

        # Normalize to lines regardless of whether Output is string[] or a
        # single string, then find the expiration header (case-insensitive).
        $lines = ($result.Output | Out-String) -split '\r?\n'
        $headerLine = $lines | Where-Object { $_ -match '^github-authentication-token-expiration:' } | Select-Object -First 1

        if (-not $headerLine) {
            # Absent header: the token has no expiration (OAuth / GITHUB_TOKEN).
            # This is a normal state, not an error.
            return [PSCustomObject] [ordered] @{
                HasExpiration = $false
                ExpiresAt     = $null
                DaysRemaining = $null
            }
        }

        # Header format: "github-authentication-token-expiration: 2027-06-17 17:43:34 UTC".
        # Split on the first colon only; the value itself contains colons.
        $expString = ($headerLine -split ':\s*', 2)[1].Trim()
        try {
            $expDate = [System.DateTime]::ParseExact(
                $expString,
                'yyyy-MM-dd HH:mm:ss UTC',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }
        catch {
            Write-Error -Message ('Token expiration header present but unparseable: [{0}].' -f $expString) -ErrorAction Stop
        }

        $daysRemaining = [System.Int32] [System.Math]::Floor(($expDate - [System.DateTime]::UtcNow).TotalDays)

        [PSCustomObject] [ordered] @{
            HasExpiration = $true
            ExpiresAt     = $expDate
            DaysRemaining = $daysRemaining
        }
    }
}
