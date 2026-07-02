#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psd1'
    $script:LoaderPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psm1'
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
