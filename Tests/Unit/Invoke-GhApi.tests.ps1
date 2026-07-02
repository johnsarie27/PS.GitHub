#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/Invoke-GhApi.ps1.
#
# Approach: mock `Invoke-Gh` (a regular PowerShell function, easy to Mock
# in Pester) to return synthetic PSCustomObjects covering the four
# behavioral surfaces: happy path, silent-404, error path, and empty
# PUT/DELETE. This is exactly the payoff of the private-wrapper ADR-6 --
# without it, we would have to shadow the native `gh` command in the
# module's session state, which is far messier.

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

Describe 'Invoke-GhApi' {
    Context 'GET happy path' {
        It 'parses JSON and returns a deserialized object' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 0
                        Output    = '{"name":"gh-org","full_name":"PS-MCS/gh-org"}'
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }

                $r = Invoke-GhApi -Path 'repos/PS-MCS/gh-org'
                $r.name | Should -Be 'gh-org'
                $r.full_name | Should -Be 'PS-MCS/gh-org'
            }
        }
        It 'builds the correct gh arg array (api, path, -X, -H)' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                Invoke-GhApi -Path 'repos/o/r' | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $Arguments[0] -eq 'api' -and
                    $Arguments[1] -eq 'repos/o/r' -and
                    $Arguments[2] -eq '-X' -and
                    $Arguments[3] -eq 'GET' -and
                    $Arguments[4] -eq '-H' -and
                    $Arguments[5] -eq 'Accept: application/vnd.github+json'
                }
            }
        }
        It 'adds --paginate when -Paginate is used' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '[{"a":1}]'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                Invoke-GhApi -Path 'orgs/o/repos' -Paginate | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $Arguments -contains '--paginate'
                }
            }
        }
    }
    Context '-AllowNotFound (silent 404)' {
        It 'returns $null when gh reports a non-zero exit AND output contains HTTP 404' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 1
                        Output    = 'gh: HTTP 404: Not Found (https://api.github.com/repos/o/r/contents/missing)'
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }

                $r = Invoke-GhApi -Path 'repos/o/r/contents/missing' -AllowNotFound
                $r | Should -BeNullOrEmpty
            }
        }
        It 'still throws for non-404 non-zero exits even with -AllowNotFound' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 1
                        Output    = 'gh: HTTP 500: Internal Server Error'
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }

                { Invoke-GhApi -Path 'repos/o/r' -AllowNotFound } |
                    Should -Throw -ExpectedMessage '*HTTP 500*'
            }
        }
        It 'throws for 404 when -AllowNotFound is NOT specified' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{
                        ExitCode  = 1
                        Output    = 'gh: HTTP 404: Not Found'
                        Arguments = $Arguments
                        Duration  = [System.TimeSpan]::FromMilliseconds(5)
                    }
                }

                { Invoke-GhApi -Path 'repos/o/r' } |
                    Should -Throw -ExpectedMessage '*HTTP 404*'
            }
        }
    }
    Context 'Empty PUT/DELETE response short-circuit' {
        It 'returns $null when PUT response body is whitespace-only' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = ''; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                $r = Invoke-GhApi -Path 'repos/o/r/topics' -Method PUT -Body '{"names":[]}'
                $r | Should -BeNullOrEmpty
            }
        }
        It 'returns $null when DELETE response body is whitespace-only' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = "  `n  "; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                $r = Invoke-GhApi -Path 'repos/o/r/labels/bug' -Method DELETE
                $r | Should -BeNullOrEmpty
            }
        }
        It 'still parses non-empty PUT responses as JSON' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"names":["a","b"]}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                $r = Invoke-GhApi -Path 'repos/o/r/topics' -Method PUT -Body '{"names":["a","b"]}'
                $r.names | Should -Be @('a', 'b')
            }
        }
    }
    Context '-Body forwarding' {
        It 'adds `--input -` to the arg array and forwards a single-string Body to Invoke-Gh' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                Invoke-GhApi -Path 'repos/o/r/topics' -Method PUT -Body '{"names":[]}' | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    ($Arguments -contains '--input') -and
                    ($Arguments -contains '-') -and
                    ($StandardInput -join "`n") -eq '{"names":[]}'
                }
            }
        }
        It 'forwards a string[] Body verbatim to Invoke-Gh (Invoke-Gh handles the join)' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                # Simulates a caller doing $b = git show HEAD:body.json, which
                # yields a string[] under strict-mode transformation.
                $bodyLines = @('{', '  "names": [],', '  "type": "test"', '}')
                Invoke-GhApi -Path 'repos/o/r/topics' -Method PUT -Body $bodyLines | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $StandardInput.Count -eq 4 -and
                    $StandardInput[0] -eq '{' -and
                    $StandardInput[-1] -eq '}'
                }
            }
        }
    }
    Context 'Method plumbing' {
        It 'passes -X PUT for -Method PUT' {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                Invoke-GhApi -Path 'repos/o/r' -Method PUT -Body '{}' | Out-Null

                Should -Invoke -CommandName Invoke-Gh -Times 1 -Exactly -ParameterFilter {
                    $idx = [System.Array]::IndexOf($Arguments, '-X')
                    $idx -ge 0 -and $Arguments[$idx + 1] -eq 'PUT'
                }
            }
        }
        It 'rejects unknown methods at parameter binding' {
            InModuleScope 'PS.GitHub' {
                { Invoke-GhApi -Path 'repos/o/r' -Method 'BOGUS' } |
                    Should -Throw
            }
        }
    }
}
