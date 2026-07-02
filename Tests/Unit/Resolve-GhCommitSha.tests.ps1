#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/Resolve-GhCommitSha.ps1.
#
# Mocks Invoke-GhApi (a regular PS function) to return synthetic
# PSCustomObjects covering: lightweight-tag happy path, annotated-tag
# cross-check disagreement, branch, commit SHA, missing ref, and the
# `-CrossCheck` no-op for non-tag refs.

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

Describe -Name 'Resolve-GhCommitSha' -Fixture {
    Context -Name 'Default path (no -CrossCheck)' -Fixture {
        It -Name 'returns the commit SHA for a tag' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    [PSCustomObject] @{ sha = 'df4cb1c0698c1a3e2a6f5b9c8d7e0a1b2c3d4e5f' }
                }
                $r = Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3
                $r | Should -Be 'df4cb1c0698c1a3e2a6f5b9c8d7e0a1b2c3d4e5f'
            }
        }
        It -Name 'returns the commit SHA for a branch' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    [PSCustomObject] @{ sha = 'aaaabbbbccccdddd0011223344556677889900ff' }
                }
                $r = Resolve-GhCommitSha -Owner actions -Repo checkout -Ref main
                $r | Should -Be 'aaaabbbbccccdddd0011223344556677889900ff'
            }
        }
        It -Name 'returns the commit SHA when given a full commit SHA' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    [PSCustomObject] @{ sha = 'ffff00001111222233334444555566667777888e' }
                }
                $r = Resolve-GhCommitSha -Owner actions -Repo checkout -Ref 'ffff00001111222233334444555566667777888e'
                $r | Should -Be 'ffff00001111222233334444555566667777888e'
            }
        }
        It -Name 'calls Invoke-GhApi against the /commits/{ref} endpoint' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    [PSCustomObject] @{ sha = 'abcdef0123456789abcdef0123456789abcdef01' }
                }
                Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3 | Out-Null
                Should -Invoke -CommandName Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
                    $Path -eq 'repos/actions/checkout/commits/v6.0.3'
                }
            }
        }
        It -Name 'does NOT hit /git/refs/tags when -CrossCheck is absent' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    [PSCustomObject] @{ sha = 'abcdef0123456789abcdef0123456789abcdef01' }
                }
                Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3 | Out-Null
                Should -Invoke -CommandName Invoke-GhApi -Times 0 -Exactly -ParameterFilter {
                    $Path -like '*git/refs/tags*'
                }
            }
        }
        It -Name 'propagates a terminating error when the ref does not exist' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -MockWith {
                    Write-Error -Message 'gh api GET repos/o/r/commits/nope failed: HTTP 404' -ErrorAction Stop
                }
                { Resolve-GhCommitSha -Owner o -Repo r -Ref nope } |
                    Should -Throw -ExpectedMessage '*HTTP 404*'
            }
        }
    }
    Context -Name '-CrossCheck path' -Fixture {
        It -Name 'lightweight tag: /commits and /git/refs/tags agree -> no warning, returns commit SHA' -Test {
            InModuleScope 'PS.GitHub' {
                $agreeSha = '1111222233334444555566667777888899990000'
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/commits/*' } -MockWith {
                    [PSCustomObject] @{ sha = $agreeSha }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/git/refs/tags/*' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = $agreeSha; type = 'commit' } }
                }
                $r = Resolve-GhCommitSha -Owner o -Repo r -Ref v1.0.0 -CrossCheck -WarningAction SilentlyContinue -WarningVariable warnings
                $r | Should -Be $agreeSha
                $warnings | Should -BeNullOrEmpty
            }
        }
        It -Name 'annotated tag: /commits and /git/refs/tags disagree -> emits warning, returns commit SHA' -Test {
            # This is the load-bearing test. Documents the exact incident
            # from 2026-06-17 (PS-MCS/gh-org PR #13, actions/checkout@v6.0.3):
            # /git/refs/tags returned 9f698171... (tag object) while
            # /commits returned df4cb1c069... (commit). Only the commit
            # SHA is safe for Actions pinning.
            InModuleScope 'PS.GitHub' {
                $commitSha = 'df4cb1c0698c1a3e2a6f5b9c8d7e0a1b2c3d4e5f'
                $tagObjectSha = '9f6981713579bdf0246810cafe0badcafe1234ab'
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/commits/*' } -MockWith {
                    [PSCustomObject] @{ sha = $commitSha }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/git/refs/tags/*' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = $tagObjectSha; type = 'tag' } }
                }
                $r = Resolve-GhCommitSha -Owner actions -Repo checkout -Ref v6.0.3 -CrossCheck -WarningAction SilentlyContinue -WarningVariable warnings
                $r | Should -Be $commitSha
                # Warning fired, and it names both SHAs so the caller can
                # audit which annotated tags they are dealing with.
                $warnings.Count | Should -BeGreaterOrEqual 1
                $warnings[0].Message | Should -Match ([regex]::Escape($commitSha))
                $warnings[0].Message | Should -Match ([regex]::Escape($tagObjectSha))
            }
        }
        It -Name 'branch under -CrossCheck: /git/refs/tags 404s (silent) -> no warning, returns commit SHA' -Test {
            InModuleScope 'PS.GitHub' {
                $commitSha = 'branchbranchbranchbranchbranchbranchbran'
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/commits/*' } -MockWith {
                    [PSCustomObject] @{ sha = $commitSha }
                }
                # /git/refs/tags/main returns 404 for a branch. -AllowNotFound
                # is set inside Resolve-GhCommitSha, so Invoke-GhApi should
                # return $null (mocked here) without throwing.
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/git/refs/tags/*' } -MockWith {
                    $null
                }
                $r = Resolve-GhCommitSha -Owner o -Repo r -Ref main -CrossCheck -WarningAction SilentlyContinue -WarningVariable warnings
                $r | Should -Be $commitSha
                $warnings | Should -BeNullOrEmpty
            }
        }
        It -Name 'passes -AllowNotFound to the /git/refs/tags Invoke-GhApi call' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/commits/*' } -MockWith {
                    [PSCustomObject] @{ sha = 'aaaa' }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*/git/refs/tags/*' } -MockWith {
                    $null
                }
                Resolve-GhCommitSha -Owner o -Repo r -Ref main -CrossCheck | Out-Null
                Should -Invoke -CommandName Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
                    ($Path -like '*/git/refs/tags/*') -and $AllowNotFound
                }
            }
        }
    }
    Context -Name 'Parameter validation' -Fixture {
        It -Name 'rejects an empty Owner' -Test {
            { Resolve-GhCommitSha -Owner '' -Repo r -Ref v1 } | Should -Throw
        }
        It -Name 'rejects an empty Repo' -Test {
            { Resolve-GhCommitSha -Owner o -Repo '' -Ref v1 } | Should -Throw
        }
        It -Name 'rejects an empty Ref' -Test {
            { Resolve-GhCommitSha -Owner o -Repo r -Ref '' } | Should -Throw
        }
    }
}
