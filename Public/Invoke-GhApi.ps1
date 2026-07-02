function Invoke-GhApi {
    <#
    .SYNOPSIS
        Wrapper around `gh api` with pagination, method/body, and silent-404 handling.
    .DESCRIPTION
        Invokes the GitHub CLI's `gh api` subcommand with a normalized
        parameter shape and returns the deserialized JSON response.

        Behavior:
          - Throws a terminating error on any non-zero exit from `gh`,
            including HTTP 4xx/5xx, unless `-AllowNotFound` is specified
            and the failure is an HTTP 404 (in which case `$null` is
            returned).
          - `-Paginate` delegates to `gh`'s `--paginate` flag for
            Link-header pagination. For GitHub REST endpoints that return
            a JSON array, `gh` merges pages into a single array; no
            `--jq '.[]'` flatten step is needed.
          - `-Body` is piped through `gh`'s `--input -` for
            PUT/POST/PATCH/DELETE requests. Accepts either a single string
            or a per-line `string[]` (normalized by `Invoke-Gh`).
          - Empty PUT/DELETE responses return `$null` instead of raising a
            JSON parse error.

        Internally invokes `gh` through the private `Invoke-Gh` wrapper,
        which owns `$PSNativeCommandUseErrorActionPreference` isolation
        (ADR-4) and `string[]` boundary normalization (ADR-6). See
        [ADR-6](../docs/adr/0006-private-invoke-gh-wrapper.md).

        This function does NOT implement `SupportsShouldProcess`. The
        caller is responsible for gating writes; most reconcilers pattern
        their public functions after `Invoke-WebRequest` /
        `Invoke-RestMethod` and gate writes via their own `-Apply` switch.
    .PARAMETER Path
        The `gh api` path or endpoint (e.g. `'repos/PS-MCS/gh-org'`,
        `'orgs/PS-MCS/code-security/configurations'`).
    .PARAMETER Method
        HTTP method. Defaults to `GET`.
    .PARAMETER Body
        Request body (typically JSON). Accepts `string` or `string[]`;
        `string[]` is joined with `` `n `` inside `Invoke-Gh` before being
        piped to `gh --input -`. Only meaningful for PUT/POST/PATCH/DELETE.
    .PARAMETER Paginate
        Delegate pagination to `gh` via `--paginate`. Use for endpoints
        that return a JSON array with Link-header pagination.
    .PARAMETER AllowNotFound
        Return `$null` on HTTP 404 instead of raising a terminating error.
        Use for existence checks against endpoints where "absent" is a
        valid state (e.g. Contents API reads for optional files, Custom
        Properties on repos with none set).
    .INPUTS
        None.
    .OUTPUTS
        System.Object. The deserialized JSON response (usually
        `[PSCustomObject]` or `[PSCustomObject[]]`), or `$null` for
        empty PUT/DELETE responses or `AllowNotFound` 404s.
    .EXAMPLE
        PS C:\> Invoke-GhApi -Path 'orgs/PS-MCS/repos?per_page=100&type=all' -Paginate

        Returns every repo in the org as an array of PSCustomObject.
    .EXAMPLE
        PS C:\> Invoke-GhApi -Path 'repos/PS-MCS/gh-org/contents/.github/CODEOWNERS' -AllowNotFound

        Returns the Contents API record for the file, or `$null` if the
        file does not exist.
    .EXAMPLE
        PS C:\> Invoke-GhApi -Path 'repos/PS-MCS/gh-org/contents/.github/dependabot.yml' -Method PUT -Body $json

        Writes the file via the Contents API. `$json` is a JSON string
        with `message` / `content` / `sha` / `branch` fields.
    .NOTES
        Status: Stable
        - Requires the `gh` CLI on `PATH` and an authenticated session
          (`gh auth status`). Scope requirements are endpoint-specific
          and enforced by the caller (see `Test-GhAuthScope`).
        - Preference isolation and string[] normalization happen inside
          `Invoke-Gh` (ADR-4, ADR-6). Do not invoke `& gh` directly from
          any other public function; route through `Invoke-Gh`.
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    Param(
        [Parameter(Mandatory, HelpMessage = 'The gh api path or endpoint.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Path,

        [Parameter(HelpMessage = 'HTTP method. Defaults to GET.')]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [System.String] $Method = 'GET',

        [Parameter(HelpMessage = 'Request body, piped into gh via --input -. Accepts string or string[].')]
        [System.String[]] $Body,

        [Parameter(HelpMessage = 'Delegate pagination to gh via --paginate.')]
        [System.Management.Automation.SwitchParameter] $Paginate,

        [Parameter(HelpMessage = 'Return $null on HTTP 404 instead of raising a terminating error.')]
        [System.Management.Automation.SwitchParameter] $AllowNotFound
    )

    Begin {
        Write-Verbose -Message ('Starting {0}: {1} {2}' -f $MyInvocation.MyCommand, $Method, $Path)
    }

    Process {
        # Build the gh arg array. -X <Method> IS explicit even for GET so the
        # error message below always includes the HTTP method.
        $ghArgs = @('api', $Path, '-X', $Method, '-H', 'Accept: application/vnd.github+json')
        if ($Paginate) {
            $ghArgs += '--paginate'
        }

        # Invoke via the private wrapper. When -Body is provided, tell gh to
        # read it from stdin via --input - and pass the body through
        # Invoke-Gh's -StandardInput (which handles the string[] -> string
        # normalization at the boundary).
        if ($PSBoundParameters.ContainsKey('Body')) {
            $ghArgs += '--input', '-'
            $result = Invoke-Gh -Arguments $ghArgs -StandardInput $Body
        }
        else {
            $result = Invoke-Gh -Arguments $ghArgs
        }

        if ($result.ExitCode -ne 0) {
            $text = ($result.Output | Out-String)
            if ($AllowNotFound -and $text -match 'HTTP 404') {
                return $null
            }
            Write-Error -Message ('gh api {0} {1} failed: {2}' -f $Method, $Path, $text) -ErrorAction Stop
        }

        # PUT and DELETE frequently return empty 204 bodies; short-circuit
        # before ConvertFrom-Json to avoid a noisy parse error.
        if ($Method -in @('PUT', 'DELETE')) {
            if ([System.String]::IsNullOrWhiteSpace(($result.Output | Out-String))) {
                return $null
            }
        }

        $result.Output | Out-String | ConvertFrom-Json
    }
}
