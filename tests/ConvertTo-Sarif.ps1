# Turns PSScriptAnalyzer results into SARIF, the format that GitHub Security reads. Paths come out
# relative to the repository, so that no local path ends up in the report.
function ConvertTo-AnalyzerSarif {
  param($Results, [string]$Root, [string]$ToolVersion)
  $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $levels = @{ ParseError = 'error'; Error = 'error'; Warning = 'warning'; Information = 'note' }
  $findings = @(foreach ($result in @($Results | Where-Object { $_ })) {
      $path = [string]$result.ScriptPath
      $relative = if ($path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $path.Substring($base.Length) } else { [IO.Path]::GetFileName($path) }
      [ordered]@{
        ruleId    = [string]$result.RuleName
        level     = $levels[[string]$result.Severity]
        message   = @{ text = [string]$result.Message }
        locations = @(@{
            physicalLocation = @{
              artifactLocation = @{ uri = $relative.Replace('\', '/'); uriBaseId = '%SRCROOT%' }
              region           = @{ startLine = [Math]::Max(1, [int]$result.Line); startColumn = [Math]::Max(1, [int]$result.Column) }
            }
          })
      }
    })
  $rules = @($findings | ForEach-Object { $_.ruleId } | Sort-Object -Unique | ForEach-Object { @{ id = $_ } })
  $sarif = [ordered]@{
    '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
    version   = '2.1.0'
    runs      = @(@{
        tool    = @{
          driver = @{
            name           = 'PSScriptAnalyzer'
            version        = $ToolVersion
            informationUri = 'https://github.com/PowerShell/PSScriptAnalyzer'
            rules          = $rules
          }
        }
        results = $findings
      })
  }
  return ($sarif | ConvertTo-Json -Depth 12)
}
