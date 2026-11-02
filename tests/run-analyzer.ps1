#Requires -Version 7.4
<#
.SYNOPSIS
  Checks the PowerShell scripts with PSScriptAnalyzer. Unlike run-tests.ps1, this needs that module.

.DESCRIPTION
  It only reads the scripts. A finding that is accepted is suppressed in the script itself, with the
  reason next to it: see the top of run-tests.ps1.

  Exit code 0 means no errors and no warnings. The SARIF file is written either way, so that CI can
  upload it when something is found.

.PARAMETER ModulePath
  Folder that holds the module, if it is not installed. Save-Module can fill one without installing it.

.PARAMETER SarifPath
  Where to write the results for GitHub Security.
#>
param([string]$ModulePath, [string]$SarifPath)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ConvertTo-Sarif.ps1')

if ($ModulePath) { $env:PSModulePath = $ModulePath + [IO.Path]::PathSeparator + $env:PSModulePath }
Import-Module PSScriptAnalyzer
$version = (Get-Module PSScriptAnalyzer).Version.ToString()

$results = @(Invoke-ScriptAnalyzer -Path $root -Recurse)

if ($SarifPath) {
  ConvertTo-AnalyzerSarif -Results $results -Root $root -ToolVersion $version | Set-Content -LiteralPath $SarifPath -Encoding utf8
}

foreach ($result in $results) {
  $relative = [IO.Path]::GetRelativePath($root, $result.ScriptPath)
  Write-Output "$($relative):$($result.Line) [$($result.Severity)] $($result.RuleName): $($result.Message)"
}

$serious = @($results | Where-Object { [string]$_.Severity -ne 'Information' })
Write-Output "PSScriptAnalyzer $version`: $($serious.Count) errors or warnings, $($results.Count - $serious.Count) notes"
if ($serious.Count -gt 0) { exit 1 }
exit 0
