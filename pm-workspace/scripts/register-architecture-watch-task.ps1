param(
  [string]$TaskPrefix = "PMWorkspace-ArchitectureWatch",
  [string]$DailyTime = "10:00",
  [string]$WeeklyTime = "18:00",
  [ValidateSet("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")]
  [string]$WeeklyDay = "FRI"
)

$ErrorActionPreference = "Stop"

$powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$runnerPath = Join-Path $PSScriptRoot "run-architecture-watch.ps1"

if (-not (Test-Path -LiteralPath $runnerPath)) {
  throw "Runner script not found: $runnerPath"
}

$dailyTaskName = "{0}-Daily" -f $TaskPrefix
$weeklyTaskName = "{0}-Weekly" -f $TaskPrefix

$dailyCommand = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Daily' -f $powershellExe, $runnerPath)
$weeklyCommand = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Weekly' -f $powershellExe, $runnerPath)

schtasks /Create /TN $dailyTaskName /SC DAILY /ST $DailyTime /TR $dailyCommand /F | Out-Null
schtasks /Create /TN $weeklyTaskName /SC WEEKLY /D $WeeklyDay /ST $WeeklyTime /TR $weeklyCommand /F | Out-Null

Write-Output "TASKS:REGISTERED"
Write-Output ("- daily={0} @ {1}" -f $dailyTaskName, $DailyTime)
Write-Output ("- weekly={0} @ {1} {2}" -f $weeklyTaskName, $WeeklyDay, $WeeklyTime)
Write-Output ("- latest report will be written under {0}" -f (Join-Path (Split-Path $PSScriptRoot -Parent) ".antigravity\reports\architecture-health"))

