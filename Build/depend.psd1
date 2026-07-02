@{
    # Defaults for all dependencies
    PSDependOptions  = @{
        Target     = 'CurrentUser'
        Parameters = @{
            Repository         = 'PSGallery'
            SkipPublisherCheck = $true
        }
    }

    # Build/test tooling
    Pester           = '5.7.1'
    psake            = '5.0.4'
    PSScriptAnalyzer = '1.24.0'
}
