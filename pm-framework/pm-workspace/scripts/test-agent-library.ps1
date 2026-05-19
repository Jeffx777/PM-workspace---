$ErrorActionPreference = "Stop"

$scriptsRoot = $PSScriptRoot
$steps = @(
  @{ Name = 'check-agent-metadata'; Path = 'check-agent-metadata.ps1' },
  @{ Name = 'build-agent-catalog'; Path = 'build-agent-catalog.ps1' },
  @{ Name = 'audit-antigravity'; Path = 'audit-antigravity.ps1' }
)

foreach ($step in $steps) {
  Write-Output "=== RUN $($step.Name) ==="
  & (Join-Path $scriptsRoot $step.Path)
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if (-not $?) {
    Write-Output "TEST:FAIL ($($step.Name))"
    exit 1
  }
  if ($exitCode -ne 0) {
    Write-Output "TEST:FAIL ($($step.Name))"
    exit $exitCode
  }
}

Write-Output 'TEST:PASS'
Write-Output '- Metadata validated'
Write-Output '- Catalog regenerated'
Write-Output '- Architecture audit executed'
