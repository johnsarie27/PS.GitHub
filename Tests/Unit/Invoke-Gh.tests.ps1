#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Private/Invoke-Gh.ps1.
#
# Approach: `Invoke-Gh` invokes the real `gh` binary via the call operator
# (`& gh @Arguments`). Mocking native applications in Pester requires the
# awkward function-shadow-in-InModuleScope pattern. Instead we use a real
# `gh` (preinstalled on all GitHub-hosted runners and in the module's
# devcontainer) and stick to `gh` operations that are guaranteed to work
# without auth: `gh --version` (exits 0) and `gh --no-such-flag` (exits
# non-zero with a well-known "unknown flag" message). This makes the tests
# hermetic-enough for CI without introducing native-mocking machinery.

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psd1'
    # psake's ImportStagingModule task may have already loaded the staged copy
    # of the module before Pester runs. InModuleScope requires exactly one
    # loaded instance, so tear down any pre-existing copy first.
    Get-Module -Name 'PS.GitHub' | Remove-Module -Force
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module -Name 'PS.GitHub' -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-Gh' {
    Context 'Return shape' {
        It 'returns a PSCustomObject with ExitCode, Output, Arguments, Duration' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--version')
                $r | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties.Name | Should -Contain 'ExitCode'
                $r.PSObject.Properties.Name | Should -Contain 'Output'
                $r.PSObject.Properties.Name | Should -Contain 'Arguments'
                $r.PSObject.Properties.Name | Should -Contain 'Duration'
            }
        }

        It 'reports ExitCode 0 for `gh --version` and non-empty Output' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--version')
                $r.ExitCode | Should -Be 0
                ($r.Output | Out-String) | Should -Match 'gh version'
            }
        }

        It 'echoes the Arguments verbatim on the returned object' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--version')
                $r.Arguments | Should -Be @('--version')
            }
        }

        It 'reports a positive TimeSpan Duration' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--version')
                $r.Duration | Should -BeOfType ([System.TimeSpan])
                $r.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            }
        }
    }

    Context 'Non-zero exit behavior' {
        It 'does not throw when `gh` exits non-zero' {
            InModuleScope 'PS.GitHub' {
                { Invoke-Gh -Arguments @('--no-such-flag-abcxyz') } | Should -Not -Throw
            }
        }

        It 'surfaces the non-zero ExitCode on the returned object' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--no-such-flag-abcxyz')
                $r.ExitCode | Should -Not -Be 0
            }
        }

        It 'still returns Output text (stderr merged via 2>&1)' {
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--no-such-flag-abcxyz')
                ($r.Output | Out-String) | Should -Match 'unknown flag'
            }
        }
    }

    Context 'ADR-4: $PSNativeCommandUseErrorActionPreference isolation' {
        It 'does not throw when the caller has $PSNativeCommandUseErrorActionPreference = $true' {
            # This is the load-bearing test for ADR-4. Without the isolation
            # inside Invoke-Gh, the call operator would throw a
            # NativeCommandExitException on the non-zero exit before the
            # wrapper could return the structured result.
            InModuleScope 'PS.GitHub' {
                $PSNativeCommandUseErrorActionPreference = $true
                { Invoke-Gh -Arguments @('--no-such-flag-abcxyz') } | Should -Not -Throw
                $r = Invoke-Gh -Arguments @('--no-such-flag-abcxyz')
                $r.ExitCode | Should -Not -Be 0
            }
        }
    }

    Context 'ADR-6: string[] boundary normalization on -StandardInput' {
        It 'accepts a single string' {
            InModuleScope 'PS.GitHub' {
                { Invoke-Gh -Arguments @('--version') -StandardInput 'ignored' } |
                    Should -Not -Throw
            }
        }

        It 'accepts a string[] and joins it before piping' {
            # `gh --version` ignores stdin; the test asserts that a string[]
            # -StandardInput is accepted without a type-coercion error and
            # the function returns a normal success result.
            InModuleScope 'PS.GitHub' {
                $r = Invoke-Gh -Arguments @('--version') -StandardInput @('line1', 'line2', 'line3')
                $r.ExitCode | Should -Be 0
            }
        }

        It 'accepts an empty-string -StandardInput' {
            InModuleScope 'PS.GitHub' {
                { Invoke-Gh -Arguments @('--version') -StandardInput '' } |
                    Should -Not -Throw
            }
        }
    }
}
