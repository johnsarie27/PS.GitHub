# PSake makes variables declared here available in other scriptblocks
Properties {
    $ProjectRoot = $env:BHProjectPath
    if (-not $ProjectRoot) {
        $ProjectRoot = $PSScriptRoot
    }

    $Timestamp = Get-Date -UFormat '%Y%m%d-%H%M%S'
    $PSVersion = $PSVersionTable.PSVersion.Major
    $lines = '----------------------------------------------------------------------'

    # Pester
    $TestFile = "Test-Unit_$($TimeStamp).xml"

    # Script Analyzer
    [ValidateSet('Error', 'Warning', 'Any', 'None')]
    $ScriptAnalysisFailBuildOnSeverityLevel = 'Error'
    $ScriptAnalyzerSettingsPath = "$ProjectRoot/Build/PSScriptAnalyzerSettings.psd1"

    # Build
    $ArtifactFolder = Join-Path -Path $ProjectRoot -ChildPath 'Artifacts'

    # Staging
    $StagingFolder = Join-Path -Path $ProjectRoot -ChildPath 'Staging'
    $StagingModulePath = Join-Path -Path $StagingFolder -ChildPath $env:BHProjectName
    $StagingModuleManifestPath = Join-Path -Path $StagingModulePath -ChildPath "$($env:BHProjectName).psd1"
}

# Define top-level tasks
Task 'Default' -depends 'Test'

# Show build variables
Task 'Init' {
    $lines

    Set-Location $ProjectRoot
    'Build System Details:'
    Get-Item ENV:BH*
    "`n"
}

# Setup the Artifact and Staging folders
Task 'Setup' -depends 'Init' {
    $lines

    $foldersToSetup = @(
        $ArtifactFolder
        $StagingFolder
    )

    foreach ($folderPath in $foldersToSetup) {
        Remove-Item -Path $folderPath -Recurse -Force -ErrorAction 'SilentlyContinue'
        New-Item -Path $folderPath -ItemType 'Directory' -Force | Out-String | Write-Verbose
    }
}

# Copy new module and other supporting files to Staging folder
Task 'CombineFunctionsAndStage' -depends 'Setup' {
    $lines

    # Create folders
    New-Item -Path $StagingFolder -ItemType 'Directory' -Force | Out-String | Write-Verbose
    New-Item -Path $StagingModulePath -ItemType 'Directory' -Force | Out-String | Write-Verbose

    # Copy required folders and files
    $pathsToCopy = @(
        Join-Path -Path $ProjectRoot -ChildPath 'Private'
        Join-Path -Path $ProjectRoot -ChildPath 'Public'
        Join-Path -Path $ProjectRoot -ChildPath 'README.md'
        Join-Path -Path $ProjectRoot -ChildPath ($env:BHProjectName + '.psd1')
        Join-Path -Path $ProjectRoot -ChildPath ($env:BHProjectName + '.psm1')
    )
    Copy-Item -Path $pathsToCopy -Destination $StagingModulePath -Recurse
}

# Import staged module
Task 'ImportStagingModule' -depends 'Init', 'CombineFunctionsAndStage' {
    $lines
    Write-Output -InputObject "Reloading staged module from path: [$StagingModulePath]`n"

    if (Get-Module -Name $env:BHProjectName) {
        Remove-Module -Name $env:BHProjectName -Force
    }
    Import-Module -Name $StagingModulePath -ErrorAction 'Stop' -Force
}

# Run PSScriptAnalyzer against staged module
Task 'Analyze' -depends 'ImportStagingModule' {
    $lines
    Write-Output -InputObject "Running PSScriptAnalyzer on path: [$StagingModulePath]`n"

    $Results = Invoke-ScriptAnalyzer -Path $StagingModulePath -Recurse -Settings $ScriptAnalyzerSettingsPath -Verbose:$VerbosePreference
    $Results | Select-Object 'RuleName', 'Severity', 'ScriptName', 'Line', 'Message' | Format-List

    switch ($ScriptAnalysisFailBuildOnSeverityLevel) {
        'None' {
            return
        }
        'Error' {
            Assert -conditionToCheck (
                ($Results | Where-Object 'Severity' -EQ 'Error').Count -eq 0
            ) -failureMessage 'One or more ScriptAnalyzer errors were found. Build cannot continue!'
        }
        'Warning' {
            Assert -conditionToCheck (
                ($Results | Where-Object {
                        $_.Severity -eq 'Warning' -or $_.Severity -eq 'Error'
                    }).Count -eq 0) -failureMessage 'One or more ScriptAnalyzer warnings were found. Build cannot continue!'
        }
        default {
            Assert -conditionToCheck ($analysisResult.Count -eq 0) -failureMessage 'One or more ScriptAnalyzer issues were found. Build cannot continue!'
        }
    }
}

# Run Pester tests
Task 'Test' -depends 'ImportStagingModule' {
    $lines

    # Gather test scripts as string[] (Pester's Run.Path is typed
    # System.String[]; passing FileInfo objects fails the type coercion
    # on both Linux and Windows). @(...) forces array shape even when the
    # glob matches exactly one file so that '+=' would not later throw
    # 'op_Addition not found' on a scalar FileInfo.
    $TestScripts = @(
        Get-ChildItem -Path "$ProjectRoot/Tests/*/*.tests.ps1" -ErrorAction SilentlyContinue |
            ForEach-Object FullName
    )

    if (-not $TestScripts) {
        Write-Output -InputObject 'No Pester test files found under Tests/*/*.tests.ps1. Skipping Invoke-Pester.'
        return
    }

    $TestFilePath = Join-Path -Path $ArtifactFolder -ChildPath $TestFile

    $PesterConfig = New-PesterConfiguration
    $PesterConfig.TestResult.OutputFormat = 'JUnitXml'
    $PesterConfig.TestResult.OutputPath = $TestFilePath
    $PesterConfig.TestResult.Enabled = $true
    $PesterConfig.Run.PassThru = $true
    $PesterConfig.Run.Path = $TestScripts

    $TestResults = Invoke-Pester -Configuration $PesterConfig

    if ($TestResults.FailedCount -gt 0) {
        Write-Error "Failed '$($TestResults.FailedCount)' tests, build failed"
    }
}

# Create a versioned zip file of all staged files
Task 'CreateBuildArtifact' -depends 'Init' {
    $lines

    New-Item -Path $ArtifactFolder -ItemType 'Directory' -Force | Out-String | Write-Verbose

    try {
        $manifest = Test-ModuleManifest -Path $StagingModuleManifestPath -ErrorAction 'Stop'
        [Version]$manifestVersion = $manifest.Version
    }
    catch {
        throw "Could not get manifest version from [$StagingModuleManifestPath]"
    }

    try {
        $releaseFilename = "$($env:BHProjectName)-v$($manifestVersion.ToString()).zip"
        $releasePath = Join-Path -Path $ArtifactFolder -ChildPath $releaseFilename
        Write-Output -InputObject "Creating release artifact [$releasePath] using manifest version [$manifestVersion]"
        Compress-Archive -Path "$StagingFolder/*" -DestinationPath $releasePath -Force -Verbose -ErrorAction 'Stop'
    }
    catch {
        throw "Could not create release artifact [$releasePath] using manifest version [$manifestVersion]"
    }

    Write-Output -InputObject "`nFINISHED: Release artifact creation."
}

# Cleanup dirs and files when finished
Task 'Cleanup' {
    $lines

    Write-Output -InputObject 'Cleaning leftover/unneeded artifacts'

    Remove-Item -Path $ArtifactFolder -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -Path $StagingFolder -Recurse -Force -ErrorAction 'SilentlyContinue'
}
