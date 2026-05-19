param(
  [string]$TaskName = "PMWorkspace-GeminiSync",
  [switch]$StartNow
)

$ErrorActionPreference = "Stop"

$powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$watcherPath = Join-Path $PSScriptRoot "watch-gemini-sync.ps1"
$currentUser = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME

if (-not (Test-Path -LiteralPath $watcherPath -PathType Leaf)) {
  throw "Watcher script not found: $watcherPath"
}

$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watcherPath
$action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

$task = Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Description 'Keep global .gemini/GEMINI.md synced from pm-workspace/GEMINI.md' `
  -User $currentUser `
  -RunLevel Limited `
  -Force

Write-Output "TASK:REGISTERED"
Write-Output ("- name={0}" -f $TaskName)
Write-Output ("- user={0}" -f $currentUser)
Write-Output ("- command={0} {1}" -f $powershellExe, $arguments)
Write-Output ("- state={0}" -f $task.State)

if ($StartNow) {
  Start-Process -FilePath $powershellExe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $watcherPath
  ) | Out-Null

  Write-Output "- started_now=true"
}
