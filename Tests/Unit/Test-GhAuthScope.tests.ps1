#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/Test-GhAuthScope.ps1.
#
# Mocks Invoke-Gh (a regular PS function, easily mockable via Pester)
# to return synthetic PSCustomObjects covering every documented failure
# surface plus the happy paths for both scope-list formats.

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

Describe -Name 'Test-GhAuthScope' -Fixture {
    Context -Name 'Happy path (quoted scope format)' -Fixture {
        It -Name 'returns $true when all requested scopes are present' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @(
                            'github.com'
                            '  Logged in to github.com as johnsarie27 (keyring)'
                            '  Git operations for github.com configured to use https protocol.'
                            '  Token: gho_************************************'
                            "  Token scopes: 'admin:org', 'gist', 'repo', 'workflow'"
                        )
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }
                $r = Test-GhAuthScope -RequiredScope 'workflow'
                $r | Should -BeTrue
            }
        }
        It -Name 'returns $true when all of several required scopes are present' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @("  Token scopes: 'admin:org', 'gist', 'repo', 'workflow'")
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }
                $r = Test-GhAuthScope -RequiredScope 'admin:org', 'workflow'
                $r | Should -BeTrue
            }
        }
        It -Name 'passes the (auth, status) arg pair to Invoke-Gh' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @("  Token scopes: 'workflow'")
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                Test-GhAuthScope -RequiredScope 'workflow' | Out-Null
                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $Arguments.Count -eq 2 -and
                    $Arguments[0] -eq 'auth' -and
                    $Arguments[1] -eq 'status'
                }
            }
        }
    }
    Context -Name 'Happy path (bare comma-separated scope format)' -Fixture {
        It -Name 'returns $true when scopes appear in the older unquoted format' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @('  - Token scopes: admin:org, gist, repo, workflow')
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }
                $r = Test-GhAuthScope -RequiredScope 'workflow'
                $r | Should -BeTrue
            }
        }
    }
    Context -Name 'Missing-scope error path' -Fixture {
        It -Name 'throws with the gh auth refresh remediation when one scope is missing' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @("  Token scopes: 'repo', 'admin:org'")
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                { Test-GhAuthScope -RequiredScope 'workflow' } |
                    Should -Throw -ExpectedMessage '*gh auth refresh -h github.com -s workflow*'
            }
        }
        It -Name 'lists ALL missing scopes in the remediation (comma-joined)' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @("  Token scopes: 'repo'")
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                { Test-GhAuthScope -RequiredScope 'workflow', 'admin:org' } |
                    Should -Throw -ExpectedMessage '*gh auth refresh -h github.com -s workflow,admin:org*'
            }
        }
        It -Name 'does NOT substring-match: `admin` required, only `admin:org` present -> throws' -Test {
            # The reference PS-MCS/gh-org code used regex substring matching
            # which would falsely say `admin` is present when only `admin:org`
            # is granted. This test locks in the exact-match improvement.
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @("  Token scopes: 'admin:org'")
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                { Test-GhAuthScope -RequiredScope 'admin' } |
                    Should -Throw -ExpectedMessage '*admin*'
            }
        }
    }
    Context -Name 'Not-authenticated error path' -Fixture {
        It -Name 'throws with the gh auth login remediation when gh auth status exits non-zero' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 1
                        Output = @('You are not logged into any GitHub hosts. Run gh auth login to authenticate.')
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                { Test-GhAuthScope -RequiredScope 'workflow' } |
                    Should -Throw -ExpectedMessage '*gh auth login*'
            }
        }
    }
    Context -Name 'Unexpected-output error path' -Fixture {
        It -Name 'throws with a diagnostic message when gh auth status output has no Token scopes: line' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode = 0
                        Output = @('some completely unrelated output that gh might one day emit')
                        Arguments = $Arguments
                        Duration = [System.TimeSpan]::Zero
                    }
                }
                { Test-GhAuthScope -RequiredScope 'workflow' } |
                    Should -Throw -ExpectedMessage "*Unable to locate 'Token scopes:'*"
            }
        }
    }
    Context -Name 'Parameter validation' -Fixture {
        It -Name 'rejects a null RequiredScope' -Test {
            { Test-GhAuthScope -RequiredScope $null } | Should -Throw
        }
        It -Name 'rejects an empty RequiredScope' -Test {
            { Test-GhAuthScope -RequiredScope @() } | Should -Throw
        }
    }
}
