function Invoke-Gh {
    <#
    .SYNOPSIS
        Internal lowest-level wrapper around the `gh` CLI.
    .DESCRIPTION
        Invokes `gh` with the supplied arguments and returns a structured
        result object with `ExitCode`, `Output`, `Arguments`, and `Duration`.

        Every public function in PS.GitHub that invokes `gh` goes through
        this helper. Direct `& gh` calls in `Public/` are a review-reject.
        Two cross-cutting rules are enforced structurally here so no
        public function needs to remember them:

        1. `$PSNativeCommandUseErrorActionPreference` isolation (ADR-4). The
           preference is set to `$false` at function entry so a caller with
           strict native-command error handling does not turn the `& gh` +
           `$LASTEXITCODE` pattern into a `NativeCommandExitException` before
           this function can inspect the exit code.

        2. `string[]` -> `string` normalization on `-StandardInput` (ADR-6).
           Callers can pass either a single string or a per-line array (e.g.
           output captured from `git show HEAD:path` or `gh view -q .body`),
           and the array is joined with `` `n `` before being piped into `gh`
           via stdin.

        Does NOT interpret the response, throw on non-zero exit, or parse
        JSON. Callers (`Invoke-GhApi`, `Test-GhAuthScope`, etc.) do their
        own exit-code and output-shape logic.

        Module-private helper. Not exported via the manifest.
    .PARAMETER Arguments
        Arguments to pass to `gh`, as an array of strings. For example,
        `@('api', 'repos/owner/repo')` or `@('auth', 'status')`.
    .PARAMETER StandardInput
        Optional stdin content. Accepts either a single string or a per-line
        `string[]`; a `string[]` is normalized to a single string via
        `-join "`n"` before being piped to `gh`.
    .INPUTS
        None. This function does not accept pipeline input.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with keys `ExitCode`,
        `Output`, `Arguments`, `Duration`.
    .EXAMPLE
        PS C:\> $r = Invoke-Gh -Arguments @('api', 'repos/PS-MCS/gh-org')
        PS C:\> if ($r.ExitCode -eq 0) { $r.Output | Out-String | ConvertFrom-Json }
    .EXAMPLE
        PS C:\> $r = Invoke-Gh -Arguments @('api', 'repos/o/r/contents/f', '-X', 'PUT', '--input', '-') -StandardInput $jsonBody
    .NOTES
        Status: Stable
        - Never throws on non-zero `gh` exit. The caller inspects `ExitCode`
          on the returned object.
        - Isolates `$PSNativeCommandUseErrorActionPreference` (ADR-4).
        - Requires the `gh` CLI on `PATH`.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Arguments to pass to gh.')]
        [ValidateNotNullOrEmpty()]
        [System.String[]] $Arguments,

        [Parameter(HelpMessage = 'Optional stdin content (accepts string or string[]).')]
        [AllowEmptyString()]
        [System.String[]] $StandardInput
    )
    Begin {
        # ADR-4: isolate the preference so callers with strict native-command
        # error handling do not short-circuit exit-code inspection. Because
        # this is a preference variable and PowerShell restores scoped
        # variables on function return, no `finally` cleanup is required.
        $PSNativeCommandUseErrorActionPreference = $false

        Write-Verbose -Message ('Starting {0}: gh {1}' -f $MyInvocation.MyCommand, ($Arguments -join ' '))
    }
    Process {
        $startTime = Get-Date

        # ADR-6: string[] normalization at the boundary. Handles the common
        # capture pattern `$b = git show HEAD:path` or
        # `$b = gh issue view N -q .body`, which returns string[] (one line
        # per element) that cannot bind to a typed [System.String] target
        # without an explicit join.
        if ($PSBoundParameters.ContainsKey('StandardInput')) {
            $normalizedInput = $StandardInput -join "`n"
            $output = $normalizedInput | & gh @Arguments 2>&1
        }
        else {
            $output = & gh @Arguments 2>&1
        }
        $exit = $LASTEXITCODE

        [PSCustomObject] @{
            ExitCode  = $exit
            Output    = $output
            Arguments = $Arguments
            Duration  = (Get-Date) - $startTime
        }
    }
}
