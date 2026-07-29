#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/New-GhSignedCommit.ps1.
#
# Approach: mock the REST layer (`Invoke-GhApi`) for the base-ref read,
# head-ref existence probe, and the branch create/reset, and mock the
# private `Invoke-Gh` for the GraphQL createCommitOnBranch call. New-GhBody
# runs for real: it writes the payload to a temp file and invokes the
# ScriptBlock, so the Invoke-Gh mock can read that file back to assert the
# exact payload shape (base64 encoding, expectedHeadOid, fileChanges).

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

Describe -Name 'New-GhSignedCommit' -Fixture {
    Context -Name 'Branch positioning' -Fixture {
        It -Name 'force-resets an existing head branch (PATCH) and returns the commit oid' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                # Head branch exists -> non-null probe result -> PATCH path.
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -eq 'PATCH' } -MockWith { $null }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -eq 'POST' } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"newcommitoid1234"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                $oid = New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' }

                $oid | Should -Be 'newcommitoid1234'
                Should -Invoke -CommandName Invoke-GhApi -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
                Should -Invoke -CommandName Invoke-GhApi -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
            }
        }
        It -Name 'creates the head branch (POST) when it does not exist' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                # Head branch absent -> probe returns $null -> POST path.
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/automation/x' } -MockWith { $null }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -eq 'PATCH' } -MockWith { $null }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -eq 'POST' } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"oid"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' } | Out-Null

                Should -Invoke -CommandName Invoke-GhApi -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
                Should -Invoke -CommandName Invoke-GhApi -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
            }
        }
        It -Name 'passes -AllowNotFound on the head-ref existence probe' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -eq 'repos/o/r/git/ref/heads/automation/x' } -MockWith { $null }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -eq 'POST' } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"oid"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' } | Out-Null

                Should -Invoke -CommandName Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
                    ($Path -eq 'repos/o/r/git/ref/heads/automation/x') -and $AllowNotFound
                }
            }
        }
    }
    Context -Name 'Payload shape' -Fixture {
        It -Name 'base64-encodes Content as UTF-8 and sets expectedHeadOid to the base SHA' -Test {
            InModuleScope 'PS.GitHub' {
                $script:baseSha = '1111111111111111111111111111111111111111'
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = $baseSha } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith { $null }
                # Read the payload New-GhBody wrote to the temp file (still on
                # disk during the ScriptBlock) and stash it for assertions.
                Mock -CommandName Invoke-Gh -MockWith {
                    $script:captured = Get-Content -LiteralPath $Arguments[3] -Raw | ConvertFrom-Json
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"oid"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                # Non-ASCII headline built at runtime (source stays ASCII) to
                # exercise the UTF-8 round-trip through New-GhBody's temp file.
                $headline = 'h' + [System.Char] 0x00E9 + 'llo'
                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline $headline -Addition @{ Path = 'a.txt'; Content = 'alpha' } | Out-Null

                $inputObj = $script:captured.variables.input
                $inputObj.expectedHeadOid | Should -Be $baseSha
                $inputObj.branch.repositoryNameWithOwner | Should -Be 'o/r'
                $inputObj.branch.branchName | Should -Be 'automation/x'
                $inputObj.message.headline | Should -Be $headline
                $expectedB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('alpha'))
                $inputObj.fileChanges.additions[0].path | Should -Be 'a.txt'
                $inputObj.fileChanges.additions[0].contents | Should -Be $expectedB64
            }
        }
        It -Name 'supports multiple additions and deletions' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    $script:captured = Get-Content -LiteralPath $Arguments[3] -Raw | ConvertFrom-Json
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"oid"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                $additions = @(
                    @{ Path = 'a.txt'; Content = 'alpha' }
                    @{ Path = 'b.txt'; Content = 'beta' }
                )
                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: multi' -Addition $additions -Deletion 'old.txt' | Out-Null

                $fc = $script:captured.variables.input.fileChanges
                $fc.additions.Count | Should -Be 2
                $fc.additions.path | Should -Contain 'a.txt'
                $fc.additions.path | Should -Contain 'b.txt'
                $fc.deletions.Count | Should -Be 1
                $fc.deletions[0].path | Should -Be 'old.txt'
            }
        }
        It -Name 'reads bytes from a LiteralPath addition' -Test {
            InModuleScope 'PS.GitHub' {
                $script:srcFile = Join-Path -Path $TestDrive -ChildPath 'src.bin'
                [System.IO.File]::WriteAllBytes($script:srcFile, [byte[]] (1, 2, 3, 250, 251))
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    $script:captured = Get-Content -LiteralPath $Arguments[3] -Raw | ConvertFrom-Json
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":{"createCommitOnBranch":{"commit":{"oid":"oid"}}}}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: bin' -Addition @{ Path = 'data.bin'; LiteralPath = $script:srcFile } | Out-Null

                $expectedB64 = [System.Convert]::ToBase64String([byte[]] (1, 2, 3, 250, 251))
                $script:captured.variables.input.fileChanges.additions[0].contents | Should -Be $expectedB64
            }
        }
    }
    Context -Name 'GraphQL error handling' -Fixture {
        It -Name 'throws when the GraphQL response carries an errors array (HTTP 200 on error)' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{"data":null,"errors":[{"message":"Ref update failed"}]}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' } } |
                    Should -Throw -ExpectedMessage '*Ref update failed*'
            }
        }
        It -Name 'throws when the GraphQL call exits non-zero' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/automation/x' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'oldoldoldoldoldoldoldoldoldoldoldoldoldo' } }
                }
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 1; Output = 'gh: some failure'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' } } |
                    Should -Throw -ExpectedMessage '*createCommitOnBranch call failed*'
            }
        }
    }
    Context -Name 'Change-set validation' -Fixture {
        It -Name 'throws when neither -Addition nor -Deletion is supplied' -Test {
            InModuleScope 'PS.GitHub' {
                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' } |
                    Should -Throw -ExpectedMessage '*At least one -Addition or -Deletion*'
            }
        }
        It -Name 'throws when an addition has no Path' -Test {
            InModuleScope 'PS.GitHub' {
                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Content = 'alpha' } } |
                    Should -Throw -ExpectedMessage '*non-empty Path*'
            }
        }
        It -Name 'throws when an addition has both Content and LiteralPath' -Test {
            InModuleScope 'PS.GitHub' {
                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha'; LiteralPath = './x' } } |
                    Should -Throw -ExpectedMessage '*exactly one of Content or LiteralPath*'
            }
        }
        It -Name 'throws when an addition has neither Content nor LiteralPath' -Test {
            InModuleScope 'PS.GitHub' {
                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt' } } |
                    Should -Throw -ExpectedMessage '*exactly one of Content or LiteralPath*'
            }
        }
        It -Name 'throws when a LiteralPath addition points at a missing file' -Test {
            InModuleScope 'PS.GitHub' {
                { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; LiteralPath = './definitely-not-here.xyz' } } |
                    Should -Throw -ExpectedMessage '*LiteralPath not found*'
            }
        }
    }
    Context -Name '-WhatIf' -Fixture {
        It -Name 'performs no branch write and no commit under -WhatIf' -Test {
            InModuleScope 'PS.GitHub' {
                Mock -CommandName Invoke-GhApi -ParameterFilter { $Path -like '*git/ref/heads/main' } -MockWith {
                    [PSCustomObject] @{ object = [PSCustomObject] @{ sha = 'basebasebasebasebasebasebasebasebasebase' } }
                }
                Mock -CommandName Invoke-GhApi -MockWith { $null }
                Mock -CommandName Invoke-Gh -MockWith {
                    [PSCustomObject] @{ ExitCode = 0; Output = '{}'; Arguments = $Arguments; Duration = [System.TimeSpan]::Zero }
                }

                New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'automation/x' -Headline 'chore: x' -Addition @{ Path = 'a.txt'; Content = 'alpha' } -WhatIf | Out-Null

                Should -Invoke -CommandName Invoke-GhApi -Times 0 -Exactly -ParameterFilter { $Method -in @('PATCH', 'POST') }
                Should -Invoke -CommandName Invoke-Gh -Times 0 -Exactly
            }
        }
    }
    Context -Name 'Parameter validation' -Fixture {
        It -Name 'rejects an empty NameWithOwner' -Test {
            { New-GhSignedCommit -NameWithOwner '' -BaseBranch 'main' -HeadBranch 'h' -Headline 'x' -Addition @{ Path = 'a'; Content = 'b' } } | Should -Throw
        }
        It -Name 'rejects an empty BaseBranch' -Test {
            { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch '' -HeadBranch 'h' -Headline 'x' -Addition @{ Path = 'a'; Content = 'b' } } | Should -Throw
        }
        It -Name 'rejects an empty HeadBranch' -Test {
            { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch '' -Headline 'x' -Addition @{ Path = 'a'; Content = 'b' } } | Should -Throw
        }
        It -Name 'rejects an empty Headline' -Test {
            { New-GhSignedCommit -NameWithOwner 'o/r' -BaseBranch 'main' -HeadBranch 'h' -Headline '' -Addition @{ Path = 'a'; Content = 'b' } } | Should -Throw
        }
    }
}
