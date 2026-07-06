function Resolve-GhCommitSha {
    <#
    .SYNOPSIS
        Resolve a tag, branch, or SHA to its commit SHA on GitHub, avoiding the annotated-tag-object trap.
    .DESCRIPTION
        For GitHub Actions pinning (`uses: actions/checkout@<40-hex>`) and for
        any other case where a caller needs a stable commit SHA reference, this
        function returns the commit SHA for a given `$Ref` in a GitHub
        repository. `$Ref` may be a tag name, a branch name, or a commit SHA.

        Uses `GET /repos/{owner}/{repo}/commits/{ref}` (via `Invoke-GhApi`),
        which returns the commit that `$Ref` points at. This is the correct
        endpoint for Actions pinning:

          - For a lightweight tag: the tag ref points directly at a commit
            SHA. Both `/commits/{ref}` and `/git/refs/tags/{ref}` return the
            same 40-char SHA.
          - For an annotated tag: the tag ref points at a *tag object* (which
            has its own SHA and dereferences to the commit). `/git/refs/tags/{ref}`
            returns the tag-object SHA; `/commits/{ref}` returns the commit
            SHA. Only the commit SHA is safe to pin an Action against, because
            a tag-object SHA is not a commit and cannot be `git checkout`ed
            for inspection.

        This is a real trap: on 2026-06-17 the `PS-MCS/gh-org` PR that pinned
        `actions/checkout@v6.0.3` initially used `/git/refs/tags`, which
        returned `9f698171...` (tag object), then had to be corrected to the
        commit SHA `df4cb1c069...` from `/commits/v6.0.3`. The two SHAs
        cross-verify each other on lightweight tags and diverge on annotated
        tags.

        The optional `-CrossCheck` switch fetches both endpoints and emits a
        `Write-Warning` if they disagree. Useful when auditing a batch of pins
        for correctness.
    .PARAMETER Owner
        Repository owner (user or org). Case-insensitive to GitHub.
    .PARAMETER Repo
        Repository name.
    .PARAMETER Ref
        The ref to resolve. May be a tag name (`v6.0.3`), a branch name
        (`main`), a full-length commit SHA, or a short SHA.
    .PARAMETER CrossCheck
        When set, also fetch `/git/refs/tags/{Ref}` and emit a warning if the
        returned tag-object SHA disagrees with the commit SHA. Silently
        no-ops when the ref is not a tag (branches and commit SHAs return
        HTTP 404 from the tags endpoint).
    .INPUTS
        None.
    .OUTPUTS
        System.String. The 40-character commit SHA.
    .EXAMPLE
        PS C:\> Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3

        Returns the commit SHA that `v6.0.3` points at, suitable for
        pinning: `- uses: actions/checkout@<returned-sha> # v6.0.3`.
    .EXAMPLE
        PS C:\> Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3 -CrossCheck

        Same as above, but also queries `/git/refs/tags/v6.0.3`. If the
        annotated-tag object dereferences to a different SHA (as is typical
        for `actions/*` annotated releases), emits a warning naming both
        SHAs; returns the commit SHA regardless.
    .NOTES
        Status: Beta
        - Uses `Invoke-GhApi` internally. Inherits its silent-404 handling
          (for `-CrossCheck` against non-tag refs) and its cross-cutting
          rules (ADR-4, ADR-6).
        - The GitHub Docs page for the "Get a commit" endpoint documents
          that `{ref}` accepts either a commit SHA, a branch, or a tag:
          https://docs.github.com/rest/commits/commits#get-a-commit
        - Graded `Beta` (from `Stable`) under
          [ADR-8](../docs/adr/0008-determinism-vs-knowledge-criterion.md):
          this function's primary value is *knowledge* (which endpoint to
          use) rather than *determinism*. The endpoint-choice knowledge is
          also documented in the `pwsh-cli-json` skill. Retained in v0.1.x
          because no concrete misuse has been observed and the API surface
          was advertised in v0.1.0 release notes. Removal is on the table
          if a concrete misuse or maintenance burden surfaces.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Repository owner (user or org).')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Owner,

        [Parameter(Mandatory, HelpMessage = 'Repository name.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Repo,

        [Parameter(Mandatory, HelpMessage = 'Ref to resolve: tag name, branch name, or commit SHA.')]
        [ValidateNotNullOrEmpty()]
        [System.String] $Ref,

        [Parameter(HelpMessage = 'Also query /git/refs/tags/{Ref} and warn on tag-object-vs-commit SHA disagreement.')]
        [System.Management.Automation.SwitchParameter] $CrossCheck
    )
    Begin {
        Write-Verbose -Message ('Starting {0}: {1}/{2}@{3}' -f $MyInvocation.MyCommand, $Owner, $Repo, $Ref)
    }
    Process {
        # Primary path: /repos/{owner}/{repo}/commits/{ref} always returns a
        # commit, whether $Ref is a tag, branch, or SHA. This is the endpoint
        # Actions pins should use.
        $commitPath = 'repos/{0}/{1}/commits/{2}' -f $Owner, $Repo, $Ref
        $commit = Invoke-GhApi -Path $commitPath
        $commitSha = $commit.sha

        if ($CrossCheck) {
            # Compare against /git/refs/tags/{ref}. This endpoint returns 404
            # for anything that is not a tag (branch, raw commit SHA); we use
            # -AllowNotFound so Invoke-GhApi returns $null in that case rather
            # than raising a terminating error.
            $tagPath = 'repos/{0}/{1}/git/refs/tags/{2}' -f $Owner, $Repo, $Ref
            $tag = Invoke-GhApi -Path $tagPath -AllowNotFound

            if ($null -ne $tag -and $tag.object.sha -ne $commitSha) {
                # Annotated-tag case: /git/refs/tags returns the tag-object
                # SHA, not the commit SHA. Warn but return the commit SHA
                # (which is what the caller almost always wants).
                $msg = 'Ref [{0}] in {1}/{2} is an annotated tag: /git/refs/tags returned tag-object SHA [{3}], /commits returned commit SHA [{4}]. Using the commit SHA. This is the correct value for GitHub Actions pinning.' -f $Ref, $Owner, $Repo, $tag.object.sha, $commitSha
                Write-Warning -Message $msg
            }
        }

        $commitSha
    }
}
