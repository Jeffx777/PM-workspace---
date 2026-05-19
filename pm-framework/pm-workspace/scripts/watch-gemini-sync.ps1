param(
  [string]$SourcePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "GEMINI.md"),
  [string]$TargetPath = (Join-Path $env:USERPROFILE ".gemini\GEMINI.md"),
  [int]$DebounceMs = 500
)

$ErrorActionPreference = "Stop"

$syncScriptPath = Join-Path $PSScriptRoot "sync-gemini-global.ps1"
if (-not (Test-Path -LiteralPath $syncScriptPath -PathType Leaf)) {
  throw "Sync script not found: $syncScriptPath"
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
  throw "Source GEMINI.md not found: $SourcePath"
}

$sourceDir = Split-Path -Parent $SourcePath
$sourceName = Split-Path -Leaf $SourcePath

& $syncScriptPath -SourcePath $SourcePath -TargetPath $TargetPath | Out-Null

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $sourceDir
$watcher.Filter = $sourceName
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
$watcher.EnableRaisingEvents = $true

$syncAction = {
  Start-Sleep -Milliseconds $using:DebounceMs
  try {
    & $using:syncScriptPath -SourcePath $using:SourcePath -TargetPath $using:TargetPath | Out-Null
  } catch {
    $message = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message
    Write-Output $message
  }
}

$subscriptions = @(
  Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $syncAction
  Register-ObjectEvent -InputObject $watcher -EventName Created -Action $syncAction
  Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $syncAction
)

try {
  Write-Output ("WATCHER:RUNNING source={0} target={1}" -f $SourcePath, $TargetPath)
  while ($true) {
    Start-Sleep -Seconds 30
  }
} finally {
  foreach ($subscription in $subscriptions) {
    if ($null -ne $subscription) {
      Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
      Remove-Job -Id $subscription.Action.Id -Force -ErrorAction SilentlyContinue
    }
  }

  $watcher.EnableRaisingEvents = $false
  $watcher.Dispose()
}
