# ==============================================================================
# Filename: PS.GitHub.psm1
# Author:   Justin Johns
# ==============================================================================

# SET DIRECTORIES
$dirs = @(
    (Join-Path -Path $PSScriptRoot -ChildPath 'Public')
    (Join-Path -Path $PSScriptRoot -ChildPath 'Private')
)

# DOT SOURCE ALL PS SCRIPTS
foreach ($file in (Get-ChildItem -Path $dirs -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    . $file.FullName
}

# EXPORT MEMBERS
# Functions are intentionally omitted here. When a module manifest (.psd1) is
# present, FunctionsToExport in the manifest is the authoritative control over
# which functions are visible to the caller after Import-Module. Adding
# -Function * to Export-ModuleMember would be redundant and has no effect when
# the manifest is present.
