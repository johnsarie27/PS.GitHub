#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Public/New-GhBody.ps1.
#
# New-GhBody is fully hermetic -- it invokes a caller-supplied
# ScriptBlock rather than any external tool -- so no mocking is
# required. The function's transparent return-passthrough is the
# cleanest way to capture state observed inside the ScriptBlock
# without running into Pester 5's per-block scope-isolation trap
# (where a bare `$var = ...` inside `It` sets a local variable that
# is invisible to subsequent assertions).
#
# For failure-path tests where the ScriptBlock throws, we cannot use
# return-passthrough -- the block never returns normally. Those tests
# capture into a hashtable (a reference type) which lets the block's
# mutation survive the throw.

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path -Path $script:ProjectRoot -ChildPath 'PS.GitHub.psd1'
    Get-Module -Name 'PS.GitHub' | Remove-Module -Force
    Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module -Name 'PS.GitHub' -Force -ErrorAction SilentlyContinue
}

Describe -Name 'New-GhBody' -Fixture {
    Context -Name 'Happy path' -Fixture {
        It -Name 'writes -Text as a string to a temp file and invokes the ScriptBlock' -Test {
            $observed = New-GhBody -Text 'hello world' -ScriptBlock {
                param($path)
                [PSCustomObject] @{
                    Path    = $path
                    Content = Get-Content -LiteralPath $path -Raw
                }
            }

            $observed.Path | Should -Not -BeNullOrEmpty
            $observed.Content | Should -Be 'hello world'
        }
        It -Name 'joins string[] -Text with newlines' -Test {
            $observed = New-GhBody -Text @('line 1', 'line 2', 'line 3') -ScriptBlock {
                param($path)
                Get-Content -LiteralPath $path -Raw
            }
            $observed | Should -Be "line 1`nline 2`nline 3"
        }
        It -Name 'preserves blank-string elements as paragraph breaks' -Test {
            $observed = New-GhBody -Text @('para 1', '', 'para 2') -ScriptBlock {
                param($path)
                Get-Content -LiteralPath $path -Raw
            }
            $observed | Should -Be "para 1`n`npara 2"
        }
        It -Name 'writes the file inside [IO.Path]::GetTempPath()' -Test {
            $observed = New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                $path
            }
            $expectedRoot = [System.IO.Path]::GetTempPath()
            $observed | Should -BeLike ($expectedRoot + '*')
        }
        It -Name 'returns whatever the ScriptBlock returns (transparent passthrough)' -Test {
            $result = New-GhBody -Text 'x' -ScriptBlock { param($path); 42 }
            $result | Should -Be 42
        }
    }
    Context -Name 'Temp-file lifecycle guarantee' -Fixture {
        It -Name 'ensures the temp file exists while the ScriptBlock runs' -Test {
            $observed = New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                Test-Path -LiteralPath $path -PathType Leaf
            }
            $observed | Should -BeTrue
        }
        It -Name 'deletes the temp file after the ScriptBlock returns normally' -Test {
            $capturedPath = New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                $path
            }
            Test-Path -LiteralPath $capturedPath | Should -BeFalse
        }
        It -Name 'STILL deletes the temp file when the ScriptBlock throws (load-bearing)' -Test {
            # This is the whole reason the wrapper exists (ADR-2). If the
            # `finally` were missing, an exception in the ScriptBlock would
            # leak the temp file. Uses a hashtable-as-ref so the block's
            # mutation survives the throw for the post-check.
            $capture = @{ Path = $null }
            $threw = $false
            try {
                New-GhBody -Text 'x' -ScriptBlock {
                    param($path)
                    $capture.Path = $path
                    throw 'simulated failure inside caller ScriptBlock'
                }
            }
            catch {
                $threw = $true
            }

            $threw | Should -BeTrue
            $capture.Path | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $capture.Path | Should -BeFalse
        }
        It -Name 'propagates the ScriptBlock exception after cleanup' -Test {
            $capture = @{ Path = $null }
            $threwMessage = $null
            try {
                New-GhBody -Text 'x' -ScriptBlock {
                    param($path)
                    $capture.Path = $path
                    throw 'boom'
                }
            }
            catch {
                $threwMessage = $_.Exception.Message
            }
            $threwMessage | Should -Match 'boom'
            Test-Path -LiteralPath $capture.Path | Should -BeFalse
        }
    }
    Context -Name 'Edge cases' -Fixture {
        It -Name 'accepts an empty string' -Test {
            $observed = New-GhBody -Text '' -ScriptBlock {
                param($path)
                Get-Content -LiteralPath $path -Raw
            }
            # An empty string writes a zero-byte file; Get-Content -Raw of
            # a zero-byte file returns $null.
            $observed | Should -BeNullOrEmpty
        }
        It -Name 'accepts an empty array' -Test {
            $observed = New-GhBody -Text @() -ScriptBlock {
                param($path)
                Get-Content -LiteralPath $path -Raw
            }
            $observed | Should -BeNullOrEmpty
        }
        It -Name 'writes UTF-8 without BOM' -Test {
            $bytes = New-GhBody -Text 'hello' -ScriptBlock {
                param($path)
                [System.IO.File]::ReadAllBytes($path)
            }
            # 'hello' in UTF-8 is 68 65 6C 6C 6F -- no BOM (EF BB BF)
            # prefix. This matches gh --body-file expectations.
            $bytes.Length | Should -Be 5
            $bytes[0] | Should -Be 0x68  # 'h'
        }
        It -Name 'rejects a null ScriptBlock' -Test {
            { New-GhBody -Text 'x' -ScriptBlock $null } | Should -Throw
        }
    }
    Context -Name 'Interaction with error paths' -Fixture {
        It -Name 'still cleans up when the ScriptBlock exits via return' -Test {
            $capturedPath = New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                # `return` inside a scriptblock invoked with `&` still
                # flows through the outer function's `finally`. Test
                # confirms this.
                return $path
            }
            Test-Path -LiteralPath $capturedPath | Should -BeFalse
        }
        It -Name 'still cleans up when the ScriptBlock uses Write-Error -ErrorAction Stop' -Test {
            $capture = @{ Path = $null }
            $threw = $false
            try {
                New-GhBody -Text 'x' -ScriptBlock {
                    param($path)
                    $capture.Path = $path
                    Write-Error -Message 'caller-side terminating error' -ErrorAction Stop
                }
            }
            catch {
                $threw = $true
            }
            $threw | Should -BeTrue
            Test-Path -LiteralPath $capture.Path | Should -BeFalse
        }
    }
    Context -Name '-ArgumentList' -Fixture {
        It -Name 'invokes the ScriptBlock with the temp path plus -ArgumentList values' -Test {
            $observed = New-GhBody -Text 'x' -ArgumentList 42, 'label' -ScriptBlock {
                param($path, $issueNumber, $label)
                [PSCustomObject] @{
                    HasPath     = -not [string]::IsNullOrEmpty($path)
                    IssueNumber = $issueNumber
                    Label       = $label
                }
            }
            $observed.HasPath | Should -BeTrue
            $observed.IssueNumber | Should -Be 42
            $observed.Label | Should -Be 'label'
        }
        It -Name 'invokes the ScriptBlock with just the temp path when -ArgumentList is omitted (backward compatible)' -Test {
            $observed = New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                $args.Count
            }
            $observed | Should -Be 0
        }
    }
    Context -Name '$using: guard (ADR-9)' -Fixture {
        It -Name 'rejects a ScriptBlock referencing $using: and names the offending variable' -Test {
            $someVar = 'value'
            $sb = { param($p) gh issue comment 1 --body $using:someVar --body-file $p }
            { New-GhBody -Text 'x' -ScriptBlock $sb } | Should -Throw -ExpectedMessage '*someVar*'
        }
        It -Name 'does not create a temp file when the ScriptBlock is rejected for $using:' -Test {
            $tempDir = [System.IO.Path]::GetTempPath()
            $before = @(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue).Count

            $sb = { param($p) $using:someVar }
            try {
                New-GhBody -Text 'x' -ScriptBlock $sb
            }
            catch {
                # expected
            }

            $after = @(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue).Count
            ($after - $before) | Should -BeLessOrEqual 0
        }
        It -Name 'does not throw for a clean ScriptBlock with no $using: reference' -Test {
            { New-GhBody -Text 'x' -ScriptBlock { param($p) $p } } | Should -Not -Throw
        }
        It -Name 'allows a plain variable named similarly to "using" (no false positive)' -Test {
            $usingLabel = 'not-a-using-expression'
            { New-GhBody -Text 'x' -ScriptBlock { param($p) $usingLabel } } | Should -Not -Throw
        }
        It -Name 'names the root variable for a $using: reference with member access' -Test {
            $sb = { param($p) gh issue comment 1 --body $using:obj.Property --body-file $p }
            { New-GhBody -Text 'x' -ScriptBlock $sb } | Should -Throw -ExpectedMessage '*obj*'
        }
        It -Name 'names the root variable for a $using: reference with index access' -Test {
            $sb = { param($p) gh issue comment 1 --body $using:hash['key'] --body-file $p }
            { New-GhBody -Text 'x' -ScriptBlock $sb } | Should -Throw -ExpectedMessage '*hash*'
        }
    }
    Context -Name 'SupportsShouldProcess (-WhatIf)' -Fixture {
        It -Name 'declares SupportsShouldProcess with ConfirmImpact = Low' -Test {
            $cmd = Get-Command -Name 'New-GhBody'
            $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $cmd.Parameters.ContainsKey('Confirm') | Should -BeTrue
            # Attribute inspection: ConfirmImpact Low
            $attr = $cmd.ScriptBlock.Attributes |
                Where-Object { $_.GetType().Name -eq 'CmdletBindingAttribute' } |
                Select-Object -First 1
            $attr.SupportsShouldProcess | Should -BeTrue
            $attr.ConfirmImpact | Should -Be 'Low'
        }
        It -Name 'does NOT invoke the ScriptBlock when -WhatIf is passed' -Test {
            $capture = @{ Invoked = $false; Path = $null }
            New-GhBody -Text 'x' -ScriptBlock {
                param($path)
                $capture.Invoked = $true
                $capture.Path = $path
            } -WhatIf | Out-Null

            $capture.Invoked | Should -BeFalse
            $capture.Path | Should -BeNullOrEmpty
        }
        It -Name 'does NOT create a temp file when -WhatIf is passed' -Test {
            # Snapshot the temp directory contents before and after.
            # Under -WhatIf, no temp file should be created.
            $tempDir = [System.IO.Path]::GetTempPath()
            $before = @(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue).Count

            New-GhBody -Text 'x' -ScriptBlock { param($path) $path } -WhatIf | Out-Null

            $after = @(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue).Count
            # Allow +/- some drift from unrelated temp activity; the test
            # would fail if New-GhBody consistently left a file behind.
            ($after - $before) | Should -BeLessOrEqual 0
        }
        It -Name 'returns $null when -WhatIf is passed' -Test {
            $result = New-GhBody -Text 'x' -ScriptBlock { param($path); 'would-run' } -WhatIf
            $result | Should -BeNullOrEmpty
        }
    }
}
