param(
  [int]$FreshDaysActive = 7,
  [int]$FreshDaysReview = 7,
  [int]$FreshDaysLaunched = 30,
  [int]$DiaryFreshDays = 3,
  [int]$InboxStaleDays = 7,
  [switch]$EmitJson,
  [string]$ReportPath
)

$ErrorActionPreference = "Stop"

function Add-CheckResult {
  param(
    [System.Collections.Generic.List[object]]$Results,
    [ValidateSet("pass", "warn", "fail")]
    [string]$Level,
    [string]$Check,
    [string]$Message,
    [object]$Data = $null
  )

  $Results.Add([pscustomobject]@{
      level   = $Level
      check   = $Check
      message = $Message
      data    = $Data
    }) | Out-Null
}

function Get-MarkdownTableRows {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Prefix
  )

  return Get-Content -Encoding UTF8 $Path | Where-Object { $_ -match ("^\| {0}" -f [regex]::Escape($Prefix)) }
}

function Parse-SyncStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $status = @{}
  $pairs = $Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  foreach ($pair in $pairs) {
    $segments = $pair.Split('=', 2)
    if ($segments.Count -eq 2) {
      $status[$segments[0].Trim()] = $segments[1].Trim()
    }
  }

  return $status
}

function Get-FreshnessThreshold {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Status
  )

  switch ($Status) {
    "active" { return $FreshDaysActive }
    "review" { return $FreshDaysReview }
    "launched" { return $FreshDaysLaunched }
    default { return 0 }
  }
}

function Try-ParseDateValue {
  param(
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "-") {
    return $null
  }

  try {
    return ([datetime]::Parse($Value)).Date
  }
  catch {
    return $null
  }
}

$workspaceRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path (Split-Path $workspaceRoot -Parent) -Parent
$auditScriptPath = Join-Path $PSScriptRoot "audit-antigravity.ps1"
$registryPath = Join-Path $workspaceRoot ".antigravity/projects/REGISTRY.md"
$diaryDirectory = Join-Path $workspaceRoot ".antigravity/diary"
$workspaceDirectory = Join-Path $workspaceRoot ".antigravity/workspaces"
$inboxDirectory = Join-Path $workspaceRoot "inbox"
$propagationLogPath = Join-Path $workspaceRoot ".antigravity/propagation-log.md"
$results = [System.Collections.Generic.List[object]]::new()
$now = Get-Date

if (-not (Test-Path -LiteralPath $auditScriptPath)) {
  throw "Audit script not found: $auditScriptPath"
}
if (-not (Test-Path -LiteralPath $registryPath)) {
  throw "Registry not found: $registryPath"
}

$auditOutput = & powershell -ExecutionPolicy Bypass -File $auditScriptPath 2>&1
$auditExitCode = $LASTEXITCODE
$auditLines = @($auditOutput | ForEach-Object { $_.ToString() } | Where-Object { $_ -and $_ -notmatch '^DEBUG:' -and $_ -notmatch '^DEBUG_' })
$auditText = ($auditLines -join [Environment]::NewLine).Trim()

if ($auditExitCode -eq 0 -and $auditText -match 'AUDIT:PASS_WITH_WARNINGS') {
  Add-CheckResult -Results $results -Level "warn" -Check "control-plane-audit" -Message "Control-plane audit passed with warnings." -Data @{
    output = $auditText
  }
}
elseif ($auditExitCode -eq 0) {
  Add-CheckResult -Results $results -Level "pass" -Check "control-plane-audit" -Message "Control-plane audit passed." -Data @{
    output = $auditText
  }
}
else {
  Add-CheckResult -Results $results -Level "fail" -Check "control-plane-audit" -Message "Control-plane audit failed." -Data @{
    output = $auditText
    exit_code = $auditExitCode
  }
}

$projectRows = Get-MarkdownTableRows -Path $registryPath -Prefix "project-"
$staleProjects = [System.Collections.Generic.List[object]]::new()
$pendingArchiveProjects = [System.Collections.Generic.List[object]]::new()
$projectDateErrors = [System.Collections.Generic.List[object]]::new()
$launchedWithoutKnowledgeCard = [System.Collections.Generic.List[string]]::new()
$checkedProjectCount = 0

foreach ($row in $projectRows) {
  $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
  if ($cells.Count -lt 13) {
    $projectDateErrors.Add([pscustomobject]@{
        row = $row
        reason = "malformed_row"
      }) | Out-Null
    continue
  }

  $projectId = $cells[1]
  if ($projectId -like 'project-{*') {
    continue
  }
  $checkedProjectCount += 1
  $status = $cells[3]
  $knowledgeCard = $cells[10].Trim('`')
  $lastSyncRaw = $cells[11]
  $syncStatus = Parse-SyncStatus -Value $cells[12].Trim('`')
  $lastSync = Try-ParseDateValue -Value $lastSyncRaw

  if ($status -eq "launched" -and $knowledgeCard -eq "-") {
    $launchedWithoutKnowledgeCard.Add($projectId) | Out-Null
  }

  if ((Get-FreshnessThreshold -Status $status) -gt 0 -and $null -eq $lastSync) {
    $projectDateErrors.Add([pscustomobject]@{
        project_id = $projectId
        reason = "missing_or_invalid_last_sync_at"
        value = $lastSyncRaw
      }) | Out-Null
    continue
  }

  if ($null -eq $lastSync) {
    continue
  }

  $ageDays = [int](New-TimeSpan -Start $lastSync -End $now.Date).TotalDays
  $threshold = Get-FreshnessThreshold -Status $status

  if ($threshold -gt 0 -and $ageDays -gt $threshold) {
    $staleProjects.Add([pscustomobject]@{
        project_id = $projectId
        status = $status
        age_days = $ageDays
        threshold_days = $threshold
        last_sync_at = $lastSync.ToString("yyyy-MM-dd")
      }) | Out-Null
  }

  if ($syncStatus.ContainsKey("project_to_knowledge") -and $syncStatus["project_to_knowledge"] -eq "staged" -and $ageDays -gt 3) {
    $pendingArchiveProjects.Add([pscustomobject]@{
        project_id = $projectId
        age_days = $ageDays
        last_sync_at = $lastSync.ToString("yyyy-MM-dd")
      }) | Out-Null
  }

  if ($syncStatus.ContainsKey("knowledge_to_project") -and @("stale", "review_required") -contains $syncStatus["knowledge_to_project"]) {
    $staleProjects.Add([pscustomobject]@{
        project_id = $projectId
        status = $status
        age_days = $ageDays
        threshold_days = $threshold
        last_sync_at = $lastSync.ToString("yyyy-MM-dd")
        reason = "knowledge_to_project_{0}" -f $syncStatus["knowledge_to_project"]
      }) | Out-Null
  }
}

if ($projectDateErrors.Count -gt 0) {
  Add-CheckResult -Results $results -Level "fail" -Check "registry-dates" -Message "Project registry has invalid or missing sync dates." -Data $projectDateErrors
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "registry-dates" -Message "All projects that require sync dates have valid last_sync_at values." -Data @{
    project_count = $checkedProjectCount
  }
}

if ($staleProjects.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "project-freshness" -Message "Some projects have stale sync state or exceeded freshness thresholds." -Data $staleProjects
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "project-freshness" -Message "Project sync freshness is within thresholds." -Data @{
    thresholds = @{
      active = $FreshDaysActive
      review = $FreshDaysReview
      launched = $FreshDaysLaunched
    }
  }
}

if ($pendingArchiveProjects.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "pending-archive" -Message "Some projects have been staged for knowledge sync for more than 3 days." -Data $pendingArchiveProjects
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "pending-archive" -Message "No long-pending project_to_knowledge staging items were found."
}

if ($launchedWithoutKnowledgeCard.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "launched-knowledge-card" -Message "Some launched projects do not have a knowledge card." -Data $launchedWithoutKnowledgeCard
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "launched-knowledge-card" -Message "All launched projects have a knowledge card or no launched project requires one."
}

$diaryFiles = Get-ChildItem -LiteralPath $diaryDirectory -File |
  Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name

if ($diaryFiles.Count -eq 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "diary-freshness" -Message "No dated diary files were found."
}
else {
  $latestDiary = $diaryFiles[-1]
  $latestDiaryDate = [datetime]::ParseExact($latestDiary.BaseName, "yyyy-MM-dd", $null)
  $diaryAgeDays = [int](New-TimeSpan -Start $latestDiaryDate -End $now.Date).TotalDays

  if ($diaryAgeDays -gt $DiaryFreshDays) {
    Add-CheckResult -Results $results -Level "warn" -Check "diary-freshness" -Message "Diary has not been updated recently." -Data @{
      latest_diary = $latestDiary.Name
      age_days = $diaryAgeDays
      threshold_days = $DiaryFreshDays
    }
  }
  else {
    Add-CheckResult -Results $results -Level "pass" -Check "diary-freshness" -Message "Diary is fresh enough." -Data @{
      latest_diary = $latestDiary.Name
      age_days = $diaryAgeDays
    }
  }
}

$workspaceItems = Get-ChildItem -LiteralPath $workspaceDirectory -Force | Where-Object { $_.Name -ne "README.md" }
$workspaceLooseFiles = $workspaceItems | Where-Object { -not $_.PSIsContainer }

if ($workspaceLooseFiles.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "workspace-hygiene" -Message "Loose files were found directly under .antigravity/workspaces; task-slug folders are safer." -Data ($workspaceLooseFiles | Select-Object Name, @{ Name = "LastWriteTime"; Expression = { $_.LastWriteTime.ToString("s") } })
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "workspace-hygiene" -Message "Workspace root is clean; no loose files were found outside task folders."
}

# --- inbox 超期检查 ---
$excludedInboxNames = @("README.md", "_template.md")
$staleInboxItems = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $inboxDirectory) {
  $inboxFiles = Get-ChildItem -LiteralPath $inboxDirectory -File |
    Where-Object { $excludedInboxNames -notcontains $_.Name }
  foreach ($f in $inboxFiles) {
    $agedays = [int](New-TimeSpan -Start $f.LastWriteTime.Date -End $now.Date).TotalDays
    if ($agedays -gt $InboxStaleDays) {
      $staleInboxItems.Add([pscustomobject]@{
          file     = $f.Name
          age_days = $agedays
          threshold_days = $InboxStaleDays
        }) | Out-Null
    }
  }
}
if ($staleInboxItems.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "inbox-stale" -Message "inbox/ 中存在超过 $InboxStaleDays 天未处理的条目，请分流或归入 rejected/。" -Data $staleInboxItems
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "inbox-stale" -Message "inbox/ 无超期未处理条目。"
}

# --- launched 项目未完成 post-launch-reviewer 检查 ---
$launchedUnvalidated = [System.Collections.Generic.List[string]]::new()
foreach ($row in $projectRows) {
  $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
  if ($cells.Count -lt 4) { continue }
  $projectId = $cells[1]
  if ($projectId -like 'project-{*') { continue }
  $status = $cells[3]
  if ($status -eq "launched") {
    $launchedUnvalidated.Add($projectId) | Out-Null
  }
}
if ($launchedUnvalidated.Count -gt 0) {
  Add-CheckResult -Results $results -Level "warn" -Check "launched-post-review" -Message "以下项目状态为 launched 但尚未运行 post-launch-reviewer 完成验收，建议尽快执行。" -Data $launchedUnvalidated
}
else {
  Add-CheckResult -Results $results -Level "pass" -Check "launched-post-review" -Message "无 launched 项目遗留未验收（或已推进至 validated/post-launch-tracking）。"
}

# --- propagation-log 新鲜度检查 ---
$propagationLogStaleDays = 30
if (-not (Test-Path -LiteralPath $propagationLogPath)) {
  Add-CheckResult -Results $results -Level "warn" -Check "propagation-log" -Message "propagation-log.md 不存在，knowledge-propagator 从未留证执行。"
}
else {
  $logContent = Get-Content -Encoding UTF8 $propagationLogPath
  $realRows = $logContent | Where-Object { $_ -match '^\|\s*\d{4}-\d{2}-\d{2}\s*\|' }
  if ($realRows.Count -eq 0) {
    Add-CheckResult -Results $results -Level "warn" -Check "propagation-log" -Message "propagation-log.md 存在但无实际执行记录，knowledge-propagator 尚未被调用过。"
  }
  else {
    $lastRow = $realRows[-1]
    $dateMatch = [regex]::Match($lastRow, '\d{4}-\d{2}-\d{2}')
    if ($dateMatch.Success) {
      $lastPropDate = [datetime]::Parse($dateMatch.Value)
      $propAgeDays = [int](New-TimeSpan -Start $lastPropDate -End $now.Date).TotalDays
      if ($propAgeDays -gt $propagationLogStaleDays) {
        Add-CheckResult -Results $results -Level "warn" -Check "propagation-log" -Message "knowledge-propagator 距上次执行已超过 $propagationLogStaleDays 天，若本月有 patterns/ 变更请及时传播。" -Data @{
          last_run     = $lastPropDate.ToString("yyyy-MM-dd")
          age_days     = $propAgeDays
          threshold_days = $propagationLogStaleDays
        }
      }
      else {
        Add-CheckResult -Results $results -Level "pass" -Check "propagation-log" -Message "propagation-log 记录新鲜，knowledge-propagator 在阈值内执行过。" -Data @{
          last_run = $lastPropDate.ToString("yyyy-MM-dd")
          age_days = $propAgeDays
        }
      }
    }
    else {
      Add-CheckResult -Results $results -Level "warn" -Check "propagation-log" -Message "propagation-log.md 中找到记录行但无法解析日期，请检查格式。"
    }
  }
}

$summary = [pscustomobject]@{
  generated_at = $now.ToString("s")
  repo_root = $repoRoot
  workspace_root = $workspaceRoot
  pass_count = ($results | Where-Object { $_.level -eq "pass" }).Count
  warn_count = ($results | Where-Object { $_.level -eq "warn" }).Count
  fail_count = ($results | Where-Object { $_.level -eq "fail" }).Count
  overall = if (($results | Where-Object { $_.level -eq "fail" }).Count -gt 0) {
    "fail"
  }
  elseif (($results | Where-Object { $_.level -eq "warn" }).Count -gt 0) {
    "warn"
  }
  else {
    "pass"
  }
  results = $results
}

if ($ReportPath) {
  $reportDirectory = Split-Path -Parent $ReportPath
  if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
  }
  $summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $ReportPath
}

if ($EmitJson) {
  $summary | ConvertTo-Json -Depth 8
}
else {
  Write-Output ("ARCH_HEALTH:{0}" -f $summary.overall.ToUpperInvariant())
  Write-Output ("- pass={0} warn={1} fail={2}" -f $summary.pass_count, $summary.warn_count, $summary.fail_count)
  foreach ($result in $results) {
    Write-Output ("- [{0}] {1}: {2}" -f $result.level.ToUpperInvariant(), $result.check, $result.message)
    if ($null -ne $result.data) {
      $result.data | ConvertTo-Json -Depth 6 | ForEach-Object {
        foreach ($line in $_ -split "`r?`n") {
          Write-Output ("  {0}" -f $line)
        }
      }
    }
  }
}

if ($summary.fail_count -gt 0) {
  exit 1
}
