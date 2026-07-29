#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/Get-GhTokenExpiration.ps1.
#
# Approach: mock the private `Invoke-Gh` to return synthetic
# `gh api /user --include` output covering the four surfaces: a PAT with an
# expiration header, a token with no expiration header, a probe failure
# (non-zero exit), and a present-but-unparseable header.

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

Describe -Name 'Get-GhTokenExpiration' -Fixture {
    Context -Name 'Token with an expiration header' -Fixture {
        It -Name 'returns HasExpiration, the parsed UTC ExpiresAt, and floored DaysRemaining' -Test {
            InModuleScope 'PS.GitHub' {
                # 100 days out from a fixed UTC instant, formatted as GitHub emits it.
                $script:expDate = [System.DateTime]::SpecifyKind([System.DateTime]::UtcNow.Date.AddDays(100).AddHours(5), [System.DateTimeKind]::Utc)
                $script:headerValue = $script:expDate.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 0
                        Output    = @(
                            'HTTP/2.0 200 OK'
                            'content-type: application/json; charset=utf-8'
                            ('github-authentication-token-expiration: {0}' -f $script:headerValue)
                            'x-github-media-type: github.v3'
                            ''
                            '{"login":"octocat"}'
                        )
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::Zero
                    }
                }

                $r = Get-GhTokenExpiration

                $r.HasExpiration | Should -BeTrue
                $r.ExpiresAt | Should -Be $script:expDate
                $r.DaysRemaining | Should -BeOfType [System.Int32]
                # Floor of ~100.2 days; allow a 1-day tolerance for the tiny
                # UtcNow drift between mock setup and the function's own read.
                $r.DaysRemaining | Should -BeGreaterOrEqual 99
                $r.DaysRemaining | Should -BeLessOrEqual 100
            }
        }
        It -Name 'reports a negative DaysRemaining for an already-expired token' -Test {
            InModuleScope 'PS.GitHub' {
                $past = [System.DateTime]::UtcNow.AddDays(-10)
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 0
                        Output    = @(
                            'HTTP/2.0 200 OK'
                            ('github-authentication-token-expiration: {0} UTC' -f $past.ToString('yyyy-MM-dd HH:mm:ss'))
                            ''
                            '{"login":"octocat"}'
                        )
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::Zero
                    }
                }

                $r = Get-GhTokenExpiration
                $r.HasExpiration | Should -BeTrue
                $r.DaysRemaining | Should -BeLessThan 0
            }
        }
        It -Name 'invokes gh with api /user --include' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = @('HTTP/2.0 200 OK', ''); Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                Get-GhTokenExpiration | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $Arguments[0] -eq 'api' -and $Arguments[1] -eq '/user' -and ($Arguments -contains '--include')
                }
            }
        }
    }
    Context -Name 'Token with no expiration header' -Fixture {
        It -Name 'returns HasExpiration $false with null ExpiresAt and DaysRemaining' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 0
                        Output    = @(
                            'HTTP/2.0 200 OK'
                            'content-type: application/json; charset=utf-8'
                            'x-github-media-type: github.v3'
                            ''
                            '{"login":"octocat"}'
                        )
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::Zero
                    }
                }

                $r = Get-GhTokenExpiration
                $r.HasExpiration | Should -BeFalse
                $r.ExpiresAt | Should -BeNullOrEmpty
                $r.DaysRemaining | Should -BeNullOrEmpty
            }
        }
    }
    Context -Name 'Probe failure' -Fixture {
        It -Name 'throws a terminating error when gh api /user exits non-zero' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 1; Output = 'gh: authentication required'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                { Get-GhTokenExpiration } | Should -Throw -ExpectedMessage '*probe failed*'
            }
        }
    }
    Context -Name 'Unparseable expiration header' -Fixture {
        It -Name 'throws a terminating error when the header value cannot be parsed' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 0
                        Output    = @(
                            'HTTP/2.0 200 OK'
                            'github-authentication-token-expiration: not-a-real-date'
                            ''
                            '{"login":"octocat"}'
                        )
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::Zero
                    }
                }

                { Get-GhTokenExpiration } | Should -Throw -ExpectedMessage '*unparseable*'
            }
        }
    }
}
