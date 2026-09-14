function New-GhSignedCommit {
    <#
    .SYNOPSIS
        Create a single GitHub-signed commit that writes and/or deletes files on a branch via the GraphQL createCommitOnBranch mutation.
    .DESCRIPTION
        Replaces the "local git commit + force-push" pattern used by CI
        automation. A ruleset that requires verified signatures on the
        default branch (e.g. `gh_org_self_protect`) rejects a PR built from
        a runner's local `git` commits, because those commits are unsigned.
        Commits created through the GraphQL
        [`createCommitOnBranch`](https://docs.github.com/graphql/reference/mutations#createcommitonbranch)
        mutation with `GITHUB_TOKEN` are signed by GitHub (shown as
        **Verified**) and satisfy the rule.

        The function **replaces** `-HeadBranch` rather than appending to it.
        Each run leaves the branch holding exactly one commit on top of
        `-BaseBranch`'s current head; anything previously on `-HeadBranch`
        is discarded. Do not point `-HeadBranch` at a branch whose existing
        commits matter.

        To get there without ever leaving `-HeadBranch` equal to
        `-BaseBranch` -- the state that makes GitHub auto-close an open
        pull request -- the commit is built on a throwaway branch
        (`ps-github/tmp/<guid>`) created at the base tip, and `-HeadBranch`
        is then moved to the resulting commit in a single ref update. The
        throwaway ref is deleted in a `finally`. See
        [ADR-10](../docs/adr/0010-atomic-ref-move-for-signed-commits.md).

        Promoted from `PS-MCS/gh-org`'s `New-SignedCommitOnBranch` with three
        refinements over that original:

          1. **Decoupled from the working tree.** The original read local
             working-tree bytes for a single file path, assuming
             `cwd == repo root`. This version resolves each addition's
             content explicitly: either an in-memory string (`Content`) or
             an explicit local file (`LiteralPath`). Paths in the change set
             are repo-relative and independent of the process's working
             directory.
          2. **Multiple changes.** The mutation's `fileChanges.additions[]`
             and `fileChanges.deletions[]` are both exposed via `-Addition`
             and `-Deletion`; the original did a single addition only.
          3. **UTF-8 pinned.** The GraphQL payload (which carries the raw
             `-Headline` / `-Body`) is written to a temp file as UTF-8
             without BOM via `New-GhBody` and passed with
             `gh api graphql --input <file>`, so non-ASCII round-trips
             safely and the temp file is always cleaned up.

        Cross-cutting behavior:

          - REST calls (base-ref read, throwaway-ref create/delete,
            head-branch move) route through `Invoke-GhApi`; the GraphQL
            call routes through the private `Invoke-Gh`. No public
            function invokes `& gh` directly (ADR-6).
          - `expectedHeadOid` is set to the base head SHA, documenting the
            intended parent. Because the throwaway ref is created at that
            SHA by this same call, the guard can no longer fire; see
            ADR-10.
          - GraphQL returns HTTP 200 even on error, so the `.errors` array
            is inspected explicitly and StrictMode-safely
            (`PSObject.Properties.Name -contains 'errors'`).
    .PARAMETER NameWithOwner
        Repository in `owner/name` form, e.g. `PS-MCS/gh-org`.
    .PARAMETER BaseBranch
        Branch whose head the new commit is placed on top of, e.g. `main`.
    .PARAMETER HeadBranch
        Branch the commit is written to. Created if absent. If present it
        is **replaced**: the branch ends up holding one commit off
        `-BaseBranch` and its prior commits are discarded.
    .PARAMETER Headline
        Commit message headline (first line).
    .PARAMETER Body
        Commit message body. Optional.
    .PARAMETER Addition
        One or more file additions, each a hashtable with a repo-relative
        `Path` key and exactly one content source:

          - `Content` -- an in-memory string, encoded as UTF-8 bytes.
          - `LiteralPath` -- a local file whose raw bytes are read.

        Example: `@{ Path = 'baseline/data.json'; Content = $json }` or
        `@{ Path = 'baseline/data.json'; LiteralPath = './data.json' }`.

        At least one `-Addition` or `-Deletion` is required.
    .PARAMETER Deletion
        One or more repo-relative paths to delete, as a string array.

        At least one `-Addition` or `-Deletion` is required.
    .INPUTS
        None.
    .OUTPUTS
        System.String. The oid (SHA) of the created commit.
    .EXAMPLE
        PS C:\> New-GhSignedCommit -NameWithOwner 'PS-MCS/gh-org' -BaseBranch 'main' -HeadBranch 'automation/codeowners-baseline' -Headline 'chore(baseline): refresh CODEOWNERS baseline (auto)' -Addition @{ Path = 'codeowners/baseline/codeowners-baseline.json'; LiteralPath = './codeowners-baseline.json' }

        Replaces the automation branch with a single GitHub-signed commit
        off `main` carrying the manifest, and returns its oid.
    .EXAMPLE
        PS C:\> $changes = @(
        >>     @{ Path = 'a.txt'; Content = 'alpha' }
        >>     @{ Path = 'b.txt'; Content = 'beta' }
        >> )
        PS C:\> New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'auto/multi' -Headline 'chore: write two files' -Addition $changes -Deletion 'old.txt'

        Writes two files and deletes one in a single signed commit.
    .NOTES
        Status: Beta
        - Uses the GitHub GraphQL `createCommitOnBranch` mutation:
          https://docs.github.com/graphql/reference/mutations#createcommitonbranch
        - Promoted from `PS-MCS/gh-org`'s `New-SignedCommitOnBranch` under
          the incident-driven axis ([ADR-3](../docs/adr/0003-rejected-function-scope.md):
          two live callers depend on it) and the determinism axis
          ([ADR-8](../docs/adr/0008-determinism-vs-knowledge-criterion.md):
          base64 encoding, `expectedHeadOid` guard, the GraphQL-200-on-error
          trap, atomic ref-move semantics, and native-preference isolation
          are enforced as one unit -- a strong "ship code, not prose" case).
        - The commit is staged on a throwaway `ps-github/tmp/<guid>` branch
          so an open PR on `-HeadBranch` is never auto-closed
          ([ADR-10](../docs/adr/0010-atomic-ref-move-for-signed-commits.md),
          issue #29).
        - Preference isolation and `string[]` normalization happen inside
          `Invoke-Gh` (ADR-4, ADR-6); the REST calls route through
          `Invoke-GhApi`.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory, HelpMessage = "Repository in 'owner/name' form.")]
        [ValidateNotNullOrEmpty()]
        [System.String] $NameWithOwner,

        [Parameter(Mandatory, HelpMessage = 'Base branch whose head the commit sits on.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $BaseBranch,

        [Parameter(Mandatory, HelpMessage = 'Branch the commit is written to.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $HeadBranch,

        [Parameter(Mandatory, HelpMessage = 'Commit message headline.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Headline,

        [Parameter(HelpMessage = 'Commit message body.')]
        [System.String] $Body = '',

        [Parameter(HelpMessage = 'File additions: hashtables with a Path key and a Content or LiteralPath source.')]
        [System.Collections.Hashtable[]] $Addition,

        [Parameter(HelpMessage = 'Repo-relative paths to delete.')]
        [System.String[]] $Deletion
    )
    Begin {
        Write-Verbose -Message ('Starting {0}: {1}' -f $MyInvocation.MyCommand, $NameWithOwner)
    }
    Process {
        # A commit must change something. Reject an empty change set up front.
        if (-not $Addition -and -not $Deletion) {
            Write-Error -Message 'At least one -Addition or -Deletion is required.' -ErrorAction Stop
        }

        # Build the GraphQL additions[]: each entry resolves its content to
        # base64 from exactly one source (in-memory string or local file).
        $additions = foreach ($change in $Addition) {
            if ([System.String]::IsNullOrWhiteSpace($change.Path)) {
                Write-Error -Message 'Each -Addition requires a non-empty Path.' -ErrorAction Stop
            }
            $hasContent = $change.ContainsKey('Content')
            $hasLiteralPath = $change.ContainsKey('LiteralPath')
            if ($hasContent -eq $hasLiteralPath) {
                Write-Error -Message ('Addition [{0}] requires exactly one of Content or LiteralPath.' -f $change.Path) -ErrorAction Stop
            }

            if ($hasContent) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([System.String] $change.Content)
            }
            else {
                if (-not (Test-Path -LiteralPath $change.LiteralPath -PathType Leaf)) {
                    Write-Error -Message ('Addition [{0}] LiteralPath not found: [{1}]' -f $change.Path, $change.LiteralPath) -ErrorAction Stop
                }
                $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $change.LiteralPath).Path)
            }

            [ordered] @{ path = [System.String] $change.Path; contents = [System.Convert]::ToBase64String($bytes) }
        }

        $deletions = foreach ($path in $Deletion) {
            if ([System.String]::IsNullOrWhiteSpace($path)) {
                Write-Error -Message 'Each -Deletion path must be non-empty.' -ErrorAction Stop
            }
            [ordered] @{ path = $path }
        }

        # RESOLVE THE BASE BRANCH HEAD. Read-only; runs before ShouldProcess.
        $baseRef = Invoke-GhApi -Path ('repos/{0}/git/ref/heads/{1}' -f $NameWithOwner, $BaseBranch)
        $baseSha = $baseRef.object.sha

        # Probe HeadBranch now so the post-commit move knows whether to PATCH
        # or POST. -AllowNotFound turns a missing branch into $null.
        $headRef = Invoke-GhApi -Path ('repos/{0}/git/ref/heads/{1}' -f $NameWithOwner, $HeadBranch) -AllowNotFound

        if (-not $PSCmdlet.ShouldProcess($HeadBranch, ('Create signed commit off {0}' -f $BaseBranch))) {
            return
        }

        # BUILD THE createCommitOnBranch PAYLOAD. Only include fileChanges
        # keys that are non-empty. The branch is the throwaway ref, not
        # HeadBranch (ADR-10).
        $fileChanges = [ordered] @{ }
        if ($additions) {
            $fileChanges.additions = @($additions)
        }
        if ($deletions) {
            $fileChanges.deletions = @($deletions)
        }

        $stagingBranch = 'ps-github/tmp/{0}' -f [System.Guid]::NewGuid().ToString('N')

        $mutation = 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }'
        $inputObject = [ordered] @{
            branch          = [ordered] @{
                repositoryNameWithOwner = $NameWithOwner
                branchName              = $stagingBranch
            }
            message         = [ordered] @{ headline = $Headline; body = $Body }
            expectedHeadOid = $baseSha
            fileChanges     = $fileChanges
        }
        $payload = [ordered] @{ query = $mutation; variables = [ordered] @{ input = $inputObject } } |
            ConvertTo-Json -Depth 10 -Compress

        # CREATE THE THROWAWAY REF at the base tip. The commit is built here
        # so HeadBranch is never momentarily equal to BaseBranch, which is
        # the state that makes GitHub auto-close an open PR (ADR-10).
        $stagingBody = @{ ref = ('refs/heads/{0}' -f $stagingBranch); sha = $baseSha } | ConvertTo-Json -Compress
        Invoke-GhApi -Path ('repos/{0}/git/refs' -f $NameWithOwner) -Method POST -Body $stagingBody | Out-Null

        try {
            # CREATE THE SIGNED COMMIT. The payload is written UTF-8 (no BOM)
            # to a temp file by New-GhBody and passed via `gh api graphql
            # --input <file>` so a non-ASCII Headline/Body round-trips;
            # New-GhBody deletes the temp file even on failure. Route the gh
            # call through Invoke-Gh (ADR-6) rather than `& gh` directly.
            $response = New-GhBody -Text $payload -ScriptBlock {
                param($payloadPath)
                $result = Invoke-Gh -Arguments @('api', 'graphql', '--input', $payloadPath)
                if ($result.ExitCode -ne 0) {
                    Write-Error -Message ('createCommitOnBranch call failed: {0}' -f ($result.Output | Out-String)) -ErrorAction Stop
                }
                $result.Output | Out-String | ConvertFrom-Json
            }

            # GraphQL RETURNS HTTP 200 EVEN ON ERROR. Inspect .errors
            # explicitly. StrictMode-safe: on success the response has no
            # 'errors' property.
            if (($response.PSObject.Properties.Name -contains 'errors') -and $response.errors) {
                $detail = ($response.errors.message -join '; ')
                Write-Error -Message ('createCommitOnBranch returned errors: {0}' -f $detail) -ErrorAction Stop
            }

            $newOid = $response.data.createCommitOnBranch.commit.oid

            # MOVE HeadBranch TO THE NEW COMMIT IN ONE REF UPDATE: old head
            # straight to the signed commit, with no intermediate state.
            if ($null -ne $headRef) {
                $moveBody = @{ sha = $newOid; force = $true } | ConvertTo-Json -Compress
                Invoke-GhApi -Path ('repos/{0}/git/refs/heads/{1}' -f $NameWithOwner, $HeadBranch) -Method PATCH -Body $moveBody | Out-Null
            }
            else {
                $createBody = @{ ref = ('refs/heads/{0}' -f $HeadBranch); sha = $newOid } | ConvertTo-Json -Compress
                Invoke-GhApi -Path ('repos/{0}/git/refs' -f $NameWithOwner) -Method POST -Body $createBody | Out-Null
            }

            $newOid
        }
        finally {
            # Best-effort: an orphaned throwaway ref is harmless, and a failed
            # cleanup must not mask the real error from the try block.
            try {
                Invoke-GhApi -Path ('repos/{0}/git/refs/heads/{1}' -f $NameWithOwner, $stagingBranch) -Method DELETE -AllowNotFound | Out-Null
            }
            catch {
                Write-Warning -Message ('Failed to delete throwaway ref [{0}]: {1}' -f $stagingBranch, $_.Exception.Message)
            }
        }
    }
}
