param(
  [ValidateSet("Daily", "Weekly", "Manual")]
  [string]$Mode = "Daily",
  [string]$ReportsRoot,
  [int]$HistoryLimit = 12,
  [int]$RecurringThreshold = 3
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-DataLines {
  param(
    [object]$Data
  )

  if ($null -eq $Data) {
    return @()
  }

  if ($Data -is [string]) {
    return @($Data)
  }

  if ($Data -is [pscustomobject]) {
    return @((($Data.PSObject.Properties | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join "; "))
  }

  if ($Data -is [System.Collections.IEnumerable]) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Data) {
      if ($null -eq $item) {
        continue
      }

      if ($item -is [pscustomobject]) {
        $pairs = $item.PSObject.Properties | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }
        $lines.Add(($pairs -join "; ")) | Out-Null
      }
      else {
        $lines.Add($item.ToString()) | Out-Null
      }
    }
    return $lines
  }

  return @($Data.ToString())
}

function Get-StatusRank {
  param(
    [string]$Status
  )

  switch ($Status) {
    "pass" { return 0 }
    "warn" { return 1 }
    "fail" { return 2 }
    default { return 99 }
  }
}

function Get-StatusTrend {
  param(
    [object]$Previous,
    [object]$Current
  )

  if ($null -eq $Previous -or [string]::IsNullOrWhiteSpace($Previous.overall) -or [string]::IsNullOrWhiteSpace($Current.overall)) {
    return "first_run"
  }

  $previousRank = Get-StatusRank -Status $Previous.overall
  $currentRank = Get-StatusRank -Status $Current.overall

  if ($currentRank -lt $previousRank) {
    return "improved"
  }
  if ($currentRank -gt $previousRank) {
    return "worsened"
  }

  $previousSignals = ($Previous.results | Where-Object { $_.level -ne "pass" }).Count
  $currentSignals = ($Current.results | Where-Object { $_.level -ne "pass" }).Count

  if ($currentSignals -lt $previousSignals) {
    return "improved"
  }
  if ($currentSignals -gt $previousSignals) {
    return "worsened"
  }

  return "unchanged"
}

function Get-IssueSignature {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result
  )

  $parts = [System.Collections.Generic.List[string]]::new()
  $parts.Add($Result.level) | Out-Null
  $parts.Add($Result.check) | Out-Null
  foreach ($line in (Get-DataLines -Data $Result.data)) {
    $parts.Add($line) | Out-Null
  }

  return ($parts -join "||")
}

function Load-State {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
      updated_at = $null
      issue_counters = @{}
    }
  }

  return Get-Content -Encoding UTF8 -Raw $Path | ConvertFrom-Json
}

function Get-RecurringCountsAndState {
  param(
    [object]$State,
    [array]$CurrentResults,
    [string]$NowIso
  )

  $previousCounters = @{}
  if ($null -ne $State.issue_counters) {
    foreach ($prop in $State.issue_counters.PSObject.Properties) {
      $previousCounters[$prop.Name] = $prop.Value
    }
  }

  $newCounters = @{}
  $recurringCounts = @{}

  foreach ($result in ($CurrentResults | Where-Object { $_.level -ne "pass" })) {
    $signature = Get-IssueSignature -Result $result
    $count = 1

    if ($previousCounters.ContainsKey($result.check)) {
      $previous = $previousCounters[$result.check]
      if ($previous.signature -eq $signature) {
        $count = [int]$previous.count + 1
      }
    }

    $newCounters[$result.check] = [pscustomobject]@{
      count = $count
      level = $result.level
      signature = $signature
      last_seen_at = $NowIso
    }
    $recurringCounts[$result.check] = $count
  }

  $newState = [pscustomobject]@{
    updated_at = $NowIso
    issue_counters = [pscustomobject]$newCounters
  }

  return [pscustomobject]@{
    recurring_counts = $recurringCounts
    state = $newState
  }
}

function Add-DecisionHint {
  param(
    [System.Collections.Generic.List[object]]$Hints,
    [string]$Priority,
    [string]$Title,
    [string]$Basis,
    [string]$Decision,
    [string]$Recommendation
  )

  $Hints.Add([pscustomobject]@{
      priority = $Priority
      title = $Title
      basis = $Basis
      decision = $Decision
      recommendation = $Recommendation
    }) | Out-Null
}

function Get-DecisionHints {
  param(
    [array]$Results,
    [hashtable]$RecurringCounts,
    [int]$RecurringThresholdValue
  )

  $hints = [System.Collections.Generic.List[object]]::new()

  foreach ($result in ($Results | Where-Object { $_.level -ne "pass" })) {
    $repeatPrefix = ""
    if ($RecurringCounts.ContainsKey($result.check) -and $RecurringCounts[$result.check] -ge $RecurringThresholdValue) {
      $repeatPrefix = "Recurring issue. "
    }

    if ($result.check -eq "control-plane-audit") {
      if ($result.level -eq "fail") {
        Add-DecisionHint -Hints $hints -Priority "P0" -Title "Fix control-plane audit failures first" -Basis ($repeatPrefix + $result.message) -Decision "Pause or continue current work?" -Recommendation "Pause and repair audit failures before pushing more changes."
      }
      else {
        Add-DecisionHint -Hints $hints -Priority "P1" -Title "Clear control-plane audit warnings" -Basis ($repeatPrefix + $result.message) -Decision "Should these warnings be fixed now or explicitly accepted?" -Recommendation "Fix the warnings soon, but this does not require a full stop."
      }
      continue
    }

    if ($result.check -eq "registry-dates") {
      Add-DecisionHint -Hints $hints -Priority "P1" -Title "Clean up project registry dates" -Basis ($repeatPrefix + $result.message) -Decision "Should these projects still be active?" -Recommendation "Update last_sync_at or downgrade/archive the project."
      continue
    }

    if ($result.check -eq "project-freshness") {
      foreach ($line in (Get-DataLines -Data $result.data)) {
        Add-DecisionHint -Hints $hints -Priority "P1" -Title "Re-evaluate active project status" -Basis ($repeatPrefix + $line) -Decision "Keep active, move to review, or archive?" -Recommendation "If work is still moving, update the control plane. Otherwise change the project status."
      }
      continue
    }

    if ($result.check -eq "pending-archive") {
      foreach ($line in (Get-DataLines -Data $result.data)) {
        Add-DecisionHint -Hints $hints -Priority "P1" -Title "Decide whether to archive stable outputs" -Basis ($repeatPrefix + $line) -Decision "Archive now or accept the backlog?" -Recommendation "Clear long-running project_to_knowledge backlog first."
      }
      continue
    }

    if ($result.check -eq "launched-knowledge-card") {
      Add-DecisionHint -Hints $hints -Priority "P2" -Title "Add or waive knowledge cards for launched projects" -Basis ($repeatPrefix + $result.message) -Decision "Does this launched project need reusable knowledge capture?" -Recommendation "Add a knowledge card if the project will be reused; otherwise document the exception."
      continue
    }

    if ($result.check -eq "diary-freshness") {
      Add-DecisionHint -Hints $hints -Priority "P2" -Title "Confirm whether diary freshness still matters" -Basis ($repeatPrefix + $result.message) -Decision "Keep diary as a required truth layer?" -Recommendation "If diary stays mandatory, keep it current. Otherwise simplify the governance rules."
      continue
    }

    if ($result.check -eq "workspace-hygiene") {
      foreach ($line in (Get-DataLines -Data $result.data)) {
        Add-DecisionHint -Hints $hints -Priority "P2" -Title "Clean loose workspace files" -Basis ($repeatPrefix + $line) -Decision "Keep, move, or retire these files?" -Recommendation "Move useful files into a task-slug folder and clear the workspace root."
      }
      continue
    }
  }

  if ($hints.Count -eq 0) {
    Add-DecisionHint -Hints $hints -Priority "P3" -Title "No decision needed" -Basis "No warn/fail item was found in this run." -Decision "No action needed." -Recommendation "Keep the current pace."
  }

  return $hints
}

function Get-TokenGuidance {
  param(
    [object]$Summary,
    [hashtable]$RecurringCounts,
    [int]$RecurringThresholdValue,
    [string]$Mode
  )

  $maxRecurring = 0
  foreach ($value in $RecurringCounts.Values) {
    if ($value -gt $maxRecurring) {
      $maxRecurring = $value
    }
  }

  if ($Summary.fail_count -gt 0) {
    return "Use Codex now. Failures exist, so blind progress is likely wasteful."
  }

  if ($maxRecurring -ge $RecurringThresholdValue) {
    return "Use Codex for a focused review. A problem has repeated several times."
  }

  if ($Mode -eq "Weekly" -and $Summary.warn_count -gt 0) {
    return "Weekly review is recommended. Warnings exist, but they can be handled with a short Codex pass."
  }

  return "No extra token spend is needed now. Read the report first and only call Codex on failure, recurring warnings, or milestone review."
}

function Remove-OldWeeklyHistory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HistoryDirectory,
    [int]$Limit
  )

  if (-not (Test-Path -LiteralPath $HistoryDirectory)) {
    return
  }

  $jsonFiles = Get-ChildItem -LiteralPath $HistoryDirectory -Filter "*-weekly.json" | Sort-Object LastWriteTime -Descending
  if ($jsonFiles.Count -gt $Limit) {
    $jsonFiles | Select-Object -Skip $Limit | Remove-Item -Force
  }

  $mdFiles = Get-ChildItem -LiteralPath $HistoryDirectory -Filter "*-weekly.md" | Sort-Object LastWriteTime -Descending
  if ($mdFiles.Count -gt $Limit) {
    $mdFiles | Select-Object -Skip $Limit | Remove-Item -Force
  }
}

function Remove-LegacyNonWeeklyHistory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HistoryDirectory
  )

  if (-not (Test-Path -LiteralPath $HistoryDirectory)) {
    return
  }

  Get-ChildItem -LiteralPath $HistoryDirectory -File |
    Where-Object { $_.BaseName -match '-(daily|manual)$' } |
    Remove-Item -Force
}

$workspaceRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ReportsRoot)) {
  $ReportsRoot = Join-Path $workspaceRoot ".antigravity\reports\architecture-health"
}

$historyDirectory = Join-Path $ReportsRoot "history"
$statePath = Join-Path $ReportsRoot "state.json"
$latestJsonPath = Join-Path $ReportsRoot "latest.json"
$latestMarkdownPath = Join-Path $ReportsRoot "latest.md"
$checkScriptPath = Join-Path $PSScriptRoot "check-architecture-health.ps1"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$historyJsonPath = Join-Path $historyDirectory ("{0}-weekly.json" -f $timestamp)
$historyMarkdownPath = Join-Path $historyDirectory ("{0}-weekly.md" -f $timestamp)

Ensure-Directory -Path $ReportsRoot
Ensure-Directory -Path $historyDirectory
Remove-LegacyNonWeeklyHistory -HistoryDirectory $historyDirectory

$previousReport = $null
if (Test-Path -LiteralPath $latestJsonPath) {
  $previousReport = Get-Content -Encoding UTF8 -Raw $latestJsonPath | ConvertFrom-Json
}

$nowIso = (Get-Date).ToString("s")
$currentJson = & powershell -ExecutionPolicy Bypass -File $checkScriptPath -EmitJson
$checkExitCode = $LASTEXITCODE
$currentSummary = $currentJson | ConvertFrom-Json

$state = Load-State -Path $statePath
$stateResult = Get-RecurringCountsAndState -State $state -CurrentResults $currentSummary.results -NowIso $nowIso
$recurringCounts = $stateResult.recurring_counts
$trend = Get-StatusTrend -Previous $previousReport -Current $currentSummary
$decisionHints = Get-DecisionHints -Results $currentSummary.results -RecurringCounts $recurringCounts -RecurringThresholdValue $RecurringThreshold
$tokenGuidance = Get-TokenGuidance -Summary $currentSummary -RecurringCounts $recurringCounts -RecurringThresholdValue $RecurringThreshold -Mode $Mode

$report = [pscustomobject]@{
  generated_at = $currentSummary.generated_at
  mode = $Mode
  storage_model = "latest + state + weekly_history"
  overall = $currentSummary.overall
  pass_count = $currentSummary.pass_count
  warn_count = $currentSummary.warn_count
  fail_count = $currentSummary.fail_count
  trend = $trend
  token_guidance = $tokenGuidance
  results = $currentSummary.results
  recurring_counts = $recurringCounts
  decision_hints = $decisionHints
}

$reportJson = $report | ConvertTo-Json -Depth 10
$stateJson = $stateResult.state | ConvertTo-Json -Depth 10

$reportJson | Set-Content -Encoding UTF8 -Path $latestJsonPath
$stateJson | Set-Content -Encoding UTF8 -Path $statePath

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Architecture Watch Report") | Out-Null
$lines.Add("") | Out-Null
$lines.Add(("- Generated At: {0}" -f $report.generated_at)) | Out-Null
$lines.Add(("- Mode: {0}" -f $report.mode)) | Out-Null
$lines.Add(("- Overall: {0}" -f $report.overall.ToUpperInvariant())) | Out-Null
$lines.Add(("- Trend: {0}" -f $report.trend)) | Out-Null
$lines.Add(("- Storage Model: {0}" -f $report.storage_model)) | Out-Null
$lines.Add(("- Token Guidance: {0}" -f $report.token_guidance)) | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Summary") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| pass | warn | fail |") | Out-Null
$lines.Add("|---|---|---|") | Out-Null
$lines.Add(("| {0} | {1} | {2} |" -f $report.pass_count, $report.warn_count, $report.fail_count)) | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Findings") | Out-Null
$lines.Add("") | Out-Null

foreach ($result in $report.results) {
  $lines.Add(("### [{0}] {1}" -f $result.level.ToUpperInvariant(), $result.check)) | Out-Null
  $lines.Add($result.message) | Out-Null
  foreach ($dataLine in (Get-DataLines -Data $result.data)) {
    $lines.Add(("- {0}" -f $dataLine)) | Out-Null
  }
  if ($recurringCounts.ContainsKey($result.check) -and $recurringCounts[$result.check] -gt 1) {
    $lines.Add(("- recurring_count={0}" -f $recurringCounts[$result.check])) | Out-Null
  }
  $lines.Add("") | Out-Null
}

$lines.Add("## Decision Hints") | Out-Null
$lines.Add("") | Out-Null
foreach ($hint in $decisionHints) {
  $lines.Add(("### [{0}] {1}" -f $hint.priority, $hint.title)) | Out-Null
  $lines.Add(("- Basis: {0}" -f $hint.basis)) | Out-Null
  $lines.Add(("- Decision: {0}" -f $hint.decision)) | Out-Null
  $lines.Add(("- Recommendation: {0}" -f $hint.recommendation)) | Out-Null
  $lines.Add("") | Out-Null
}

$lines.Add("## Files") | Out-Null
$lines.Add("") | Out-Null
$lines.Add(("- Latest Markdown: {0}" -f $latestMarkdownPath)) | Out-Null
$lines.Add(("- Latest JSON: {0}" -f $latestJsonPath)) | Out-Null
$lines.Add(("- State File: {0}" -f $statePath)) | Out-Null
$lines.Add(("- Weekly History Directory: {0}" -f $historyDirectory)) | Out-Null
$lines.Add("") | Out-Null

$markdown = $lines -join "`r`n"
$markdown | Set-Content -Encoding UTF8 -Path $latestMarkdownPath

if ($Mode -eq "Weekly") {
  $reportJson | Set-Content -Encoding UTF8 -Path $historyJsonPath
  $markdown | Set-Content -Encoding UTF8 -Path $historyMarkdownPath
  Remove-OldWeeklyHistory -HistoryDirectory $historyDirectory -Limit $HistoryLimit
}

Write-Output ("ARCH_WATCH:{0}" -f $report.overall.ToUpperInvariant())
Write-Output ("- mode={0}" -f $report.mode)
Write-Output ("- trend={0}" -f $report.trend)
Write-Output ("- pass={0} warn={1} fail={2}" -f $report.pass_count, $report.warn_count, $report.fail_count)
Write-Output ("- latest_markdown={0}" -f $latestMarkdownPath)
Write-Output ("- latest_json={0}" -f $latestJsonPath)
Write-Output ("- state_file={0}" -f $statePath)
Write-Output ("- token_guidance={0}" -f $report.token_guidance)

if ($checkExitCode -ne 0) {
  exit $checkExitCode
}
