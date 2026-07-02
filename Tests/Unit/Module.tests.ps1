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

Describe -Name 'PS.GitHub module scaffold' -Fixture {
    Context -Name 'Manifest' -Fixture {
        It -Name 'exists on disk' -Test {
            Test-Path -LiteralPath $script:ManifestPath -PathType Leaf |
                Should -BeTrue
        }

        It -Name 'passes Test-ModuleManifest' -Test {
            { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } |
                Should -Not -Throw
        }

        It -Name 'declares a minimum PowerShell version of 7.4 or higher' -Test {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            $manifest.PowerShellVersion |
                Should -BeGreaterOrEqual ([System.Version]'7.4')
        }

        It -Name 'has a parseable GUID' -Test {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            { [System.Guid]::Parse($manifest.Guid) } |
                Should -Not -Throw
        }

        It -Name 'names the .psm1 loader as RootModule' -Test {
            $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
            $manifest.RootModule | Should -Be 'PS.GitHub.psm1'
        }
    }

    Context -Name 'Loader' -Fixture {
        It -Name 'exists on disk' -Test {
            Test-Path -LiteralPath $script:LoaderPath -PathType Leaf |
                Should -BeTrue
        }

        It -Name 'imports without throwing' -Test {
            { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop } |
                Should -Not -Throw
        }
    }
}
