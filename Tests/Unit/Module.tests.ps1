#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psd1'
    $script:LoaderPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psm1'
    # psake's ImportStagingModule task may have already loaded the staged copy
    # of the module before Pester runs. Tear down any pre-existing copy so the
    # 'Loader / imports without throwing' assertion below tests the intended
    # import from disk rather than a no-op re-import.
    Get-Module -Name 'PS.GitHub' | Remove-Module -Force
}

Describe 'PS.GitHub module scaffold' {
    Context 'Manifest' {
        It 'exists on disk' {
            Test-Path -LiteralPath $script:ManifestPath -PathType Leaf |
                Should -BeTrue
        }

        It 'passes Test-ModuleManifest' {
            { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } |
                Should -Not -Throw
        }

        It 'declares a minimum PowerShell version of 7.4 or higher' {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            $manifest.PowerShellVersion |
                Should -BeGreaterOrEqual ([System.Version]'7.4')
        }

        It 'has a parseable GUID' {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            { [System.Guid]::Parse($manifest.Guid) } |
                Should -Not -Throw
        }

        It 'names the .psm1 loader as RootModule' {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            $manifest.RootModule | Should -Be 'PS.GitHub.psm1'
        }
    }

    Context 'Loader' {
        It 'exists on disk' {
            Test-Path -LiteralPath $script:LoaderPath -PathType Leaf |
                Should -BeTrue
        }

        It 'imports without throwing' {
            { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop } |
                Should -Not -Throw
        }
    }
}
